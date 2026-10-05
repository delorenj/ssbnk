package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
)

func filepathJoinHosted(config Config, filename string) string {
	return filepath.Join(config.DataDir, "hosted", filename)
}

func (s *UploadSpool) publish(job *uploadJob) error {
	release, err := acquireCleanupLock(s.config.DataDir)
	if err != nil {
		return uploadError("BUSY", 503, "retention publication lock is busy", true)
	}
	defer release()
	if !job.busy.CompareAndSwap(false, true) {
		return uploadError("BUSY", 409, "publication mutation already in progress", true)
	}
	defer job.busy.Store(false)
	if job.uncertain.Load() {
		return uploadError("STORAGE_UNCERTAIN", 503, "publication requires storage reconciliation", false)
	}
	j := *job.snapshot.Load()
	if j.Receipt.State == "ready" {
		return nil
	}
	if j.Prepared == nil {
		return errors.New("publication lacks prepared checkpoint")
	}
	prepared := j.Prepared
	hosted := filepathJoinHosted(s.config, prepared.Result.Filename)
	output := s.path(j.Receipt.UUID, "output")
	if err := os.Link(output, hosted); err != nil && !os.IsExist(err) {
		if !os.IsNotExist(err) {
			return err
		}
		if err := verifyFile(hosted, prepared.Result.Size, prepared.Result.SHA256); err != nil {
			return uploadError("PUBLICATION_CONFLICT", 503, "prepared output is missing or conflicts", false)
		}
	}
	if err := verifyFile(hosted, prepared.Result.Size, prepared.Result.SHA256); err != nil {
		return uploadError("PUBLICATION_CONFLICT", 503, "hosted output conflicts with prepared checkpoint", false)
	}
	if err := syncDirectory(filepath.Dir(hosted)); err != nil {
		return uploadError("STORAGE_UNCERTAIN", 503, "hosted link durability is uncertain", false)
	}
	metadataPath := filepath.Join(s.config.DataDir, "metadata", prepared.Metadata.ID+".json")
	if err := savePreparedMetadata(prepared.Metadata, metadataPath); err != nil {
		if !os.IsExist(err) {
			return uploadError("STORAGE_UNCERTAIN", 503, "published output awaits metadata reconciliation", false)
		}
		metadata, readErr := decodeMetadataFile(metadataPath)
		if readErr != nil || !reflect.DeepEqual(metadata, prepared.Metadata) {
			return uploadError("PUBLICATION_CONFLICT", 503, "metadata conflicts with prepared checkpoint", false)
		}
		if err := syncDirectory(filepath.Dir(metadataPath)); err != nil {
			return uploadError("STORAGE_UNCERTAIN", 503, "metadata durability is uncertain", false)
		}
	}
	j.Receipt.State = "ready"
	result := prepared.Result
	j.Receipt.Result = &result
	j.Receipt.Error = nil
	if err := s.commit(job, j); err != nil {
		return uploadError("STORAGE_UNCERTAIN", 503, "ready durability is uncertain; publication will roll forward", false)
	}
	publishIngestionState(s.config, hosted, result.URL)
	s.removeCommittedIntake(j)
	if err := s.releasePrivateStorage(job); err != nil {
		return uploadError("STORAGE_UNCERTAIN", 503, "private storage cleanup is uncertain", false)
	}
	return nil
}

func savePreparedMetadata(metadata ScreenshotMetadata, path string) error {
	data, err := json.Marshal(metadata)
	if err != nil {
		return err
	}
	directory := filepath.Dir(path)
	temp, err := os.CreateTemp(directory, ".prepared-metadata-")
	if err != nil {
		return err
	}
	name := temp.Name()
	defer func() { _ = temp.Close(); _ = os.Remove(name) }()
	if err := temp.Chmod(0644); err != nil {
		return err
	}
	if _, err := temp.Write(data); err != nil {
		return err
	}
	if err := temp.Sync(); err != nil {
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Link(name, path); err != nil {
		return err
	}
	return syncDirectory(directory)
}

func protectedUploadOutputs(dataDir string) (map[string]bool, error) {
	protected := make(map[string]bool)
	directory := filepath.Join(dataDir, "spool")
	entries, err := os.ReadDir(directory)
	if os.IsNotExist(err) {
		return protected, nil
	}
	if err != nil {
		return nil, err
	}
	limits, err := uploadLimitsFromEnv()
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		id, err := canonicalUploadID(entry.Name())
		if err != nil || !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("cannot safely clean around unrecognized spool entry %q", entry.Name())
		}
		journal, err := readUploadJournal(filepath.Join(directory, id, "journal.json"), limits)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("cleanup cannot verify upload %s: %w", id, err)
		}
		if journal.Prepared != nil && journal.Receipt.State != "ready" && journal.Receipt.State != "expired" {
			protected[journal.Prepared.Result.Filename] = true
		}
	}
	return protected, nil
}
