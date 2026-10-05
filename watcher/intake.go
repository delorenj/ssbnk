package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/google/uuid"
)

type intakeIdentity struct {
	Path     string `json:"path"`
	Size     int64  `json:"size"`
	Modified int64  `json:"modified"`
	Device   uint64 `json:"device"`
	Inode    uint64 `json:"inode"`
}

func inspectIntake(path string) (intakeIdentity, error) {
	absolute, err := filepath.EvalSymlinks(path)
	if err != nil {
		return intakeIdentity{}, err
	}
	absolute, err = filepath.Abs(absolute)
	if err != nil {
		return intakeIdentity{}, err
	}
	info, err := os.Lstat(absolute)
	if err != nil {
		return intakeIdentity{}, err
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 {
		return intakeIdentity{}, errors.New("intake is not a nonempty regular file")
	}
	stat := info.Sys().(*syscall.Stat_t)
	return intakeIdentity{Path: absolute, Size: info.Size(), Modified: info.ModTime().UnixNano(), Device: uint64(stat.Dev), Inode: uint64(stat.Ino)}, nil
}

func (s *UploadSpool) runLocalIntake() {
	observations := make(map[string]struct {
		identity intakeIdentity
		since    time.Time
	})
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
		}
		seen := make(map[string]bool)
		for _, root := range []string{s.config.ScreenshotDir, s.config.ScreencastDir} {
			entries, err := os.ReadDir(root)
			if err != nil {
				continue
			}
			for _, entry := range entries {
				if !isImageFile(entry.Name()) && !isVideoFile(entry.Name()) {
					continue
				}
				identity, err := inspectIntake(filepath.Join(root, entry.Name()))
				if err != nil {
					continue
				}
				seen[identity.Path] = true
				previous, exists := observations[identity.Path]
				if !exists || previous.identity != identity {
					observations[identity.Path] = struct {
						identity intakeIdentity
						since    time.Time
					}{identity, time.Now()}
					continue
				}
				wait := 300 * time.Millisecond
				if isVideoFile(entry.Name()) {
					wait = 3 * time.Second
				}
				if time.Since(previous.since) < wait {
					continue
				}
				_ = s.claimLocalIntake(identity)
			}
		}
		for path := range observations {
			if !seen[path] {
				delete(observations, path)
			}
		}
	}
}

var localIntakeMutex sync.Mutex

func (s *UploadSpool) claimLocalIntake(identity intakeIdentity) error {
	localIntakeMutex.Lock()
	defer localIntakeMutex.Unlock()
	var existingJob *uploadJob
	for _, job := range s.jobList() {
		j := job.snapshot.Load()
		if j.Intake != nil && *j.Intake == identity {
			if j.Receipt.State == "ready" {
				s.removeCommittedIntake(*j)
				return nil
			}
			if j.Receipt.State != "receiving" {
				return nil
			}
			existingJob = job
			break
		}
	}
	kind, profile := "image", "original"
	if isVideoFile(identity.Path) {
		kind, profile = "video", "gif-30s-10fps-640"
	}
	maximum := s.limits.ImageBytes
	if kind == "video" {
		maximum = s.limits.VideoBytes
	}
	if identity.Size > maximum {
		return errors.New("local input exceeds media limit")
	}
	file, err := os.Open(identity.Path)
	if err != nil {
		return err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, contextReader{ctx: s.ctx, reader: io.LimitReader(file, identity.Size+1)}); err != nil {
		return err
	}
	current, err := inspectIntake(identity.Path)
	if err != nil || current != identity {
		return errors.New("local source changed before claim")
	}
	descriptor := UploadDescriptor{Version: uploadVersion, OriginalName: filepath.Base(identity.Path), Kind: kind, Profile: profile, Size: identity.Size, SHA256: hex.EncodeToString(hash.Sum(nil)), CaptureTime: time.Now().UTC()}
	job := existingJob
	if job == nil {
		job, _, err = s.reserve(uuid.NewString(), descriptor)
		if err != nil {
			return err
		}
	} else if job.snapshot.Load().Receipt.UploadDescriptor.SHA256 != descriptor.SHA256 {
		job.uncertain.Store(true)
		return errors.New("claimed local source hash changed without identity change")
	}
	if job.uncertain.Load() {
		return errors.New("local claim requires storage reconciliation")
	}
	if !job.busy.CompareAndSwap(false, true) {
		return errors.New("local claim is busy")
	}
	defer job.busy.Store(false)
	j := *job.snapshot.Load()
	j.Intake = &identity
	if err := s.commit(job, j); err != nil {
		return err
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	output, err := os.OpenFile(s.path(j.Receipt.UUID, "input"), os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	defer output.Close()
	if err := output.Truncate(0); err != nil {
		return err
	}
	hash = sha256.New()
	written, err := io.Copy(io.MultiWriter(output, hash), contextReader{ctx: s.ctx, reader: io.LimitReader(file, identity.Size)})
	if err != nil || written != identity.Size || hex.EncodeToString(hash.Sum(nil)) != descriptor.SHA256 {
		return errors.New("local source changed during staging")
	}
	current, err = inspectIntake(identity.Path)
	if err != nil || current != identity {
		return errors.New("local source changed during staging")
	}
	if err := output.Sync(); err != nil {
		job.uncertain.Store(true)
		return err
	}
	j.Receipt.Offset = identity.Size
	j.Receipt.ProgressAt = time.Now().UTC()
	j.Receipt.AcceptedAt = &j.Receipt.ProgressAt
	j.Receipt.State = "verifying"
	lastLength := identity.Size
	if lastLength > s.limits.ChunkBytes {
		lastLength = s.limits.ChunkBytes
	}
	lastOffset := identity.Size - lastLength
	hash = sha256.New()
	if _, err := file.Seek(lastOffset, io.SeekStart); err != nil {
		return err
	}
	if _, err := io.Copy(hash, io.LimitReader(file, lastLength)); err != nil {
		return err
	}
	j.LastChunk = &committedChunk{Offset: lastOffset, Length: lastLength, SHA256: hex.EncodeToString(hash.Sum(nil))}
	return s.commit(job, j)
}

func (s *UploadSpool) removeCommittedIntake(j uploadJournal) {
	if j.Intake == nil || j.Receipt.State != "ready" {
		return
	}
	current, err := inspectIntake(j.Intake.Path)
	if err == nil && current == *j.Intake {
		_ = os.Remove(j.Intake.Path)
	}
}

func (s *UploadSpool) checkpointPrepared(job *uploadJob, j uploadJournal, extension string, result UploadResult, metadata ScreenshotMetadata) error {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	if j.Intake != nil {
		protected := make(map[string]bool)
		for _, existing := range s.jobs {
			if prepared := existing.snapshot.Load().Prepared; prepared != nil {
				protected[prepared.Result.Filename] = true
			}
		}
		stem := metadata.Timestamp.Local().Format("20060102-1504")
		for index := 0; ; index++ {
			filename := stem + extension
			if index > 0 {
				filename = stem + "-" + strconv.Itoa(index) + extension
			}
			if protected[filename] {
				continue
			}
			if _, err := os.Lstat(filepathJoinHosted(s.config, filename)); err == nil {
				continue
			} else if !os.IsNotExist(err) {
				return err
			}
			result.Filename = filename
			result.URL = strings.TrimRight(s.config.BaseURL, "/") + "/" + filename
			metadata.Filename = filename
			metadata.URL = result.URL
			break
		}
	}
	j.Prepared = &preparedUpload{Metadata: metadata, Result: result}
	return s.commit(job, j)
}
