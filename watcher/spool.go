package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type uploadJob struct {
	busy      atomic.Bool
	uncertain atomic.Bool
	snapshot  atomic.Pointer[uploadJournal]
}

type UploadSpool struct {
	config                Config
	limits                UploadLimits
	directory             string
	owner                 *os.File
	mutex                 sync.RWMutex
	jobs                  map[string]*uploadJob
	receivers             chan struct{}
	ctx                   context.Context
	cancel                context.CancelFunc
	workers               sync.WaitGroup
	transientReservations int64
	transientSlots        int
}

func openUploadSpool(config Config, limits UploadLimits) (*UploadSpool, error) {
	directory := filepath.Join(config.DataDir, "spool")
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, fmt.Errorf("create spool: %w", err)
	}
	owner, err := os.Open(directory)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(owner.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		owner.Close()
		return nil, fmt.Errorf("spool owner lock: %w", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	spool := &UploadSpool{config: config, limits: limits, directory: directory, owner: owner, jobs: make(map[string]*uploadJob), receivers: make(chan struct{}, limits.Receivers), ctx: ctx, cancel: cancel}
	if err := spool.recover(); err != nil {
		spool.Close()
		return nil, err
	}
	return spool, nil
}

func (s *UploadSpool) Close() {
	s.cancel()
	s.workers.Wait()
	_ = syscall.Flock(int(s.owner.Fd()), syscall.LOCK_UN)
	_ = s.owner.Close()
}

func (s *UploadSpool) path(id, name string) string { return filepath.Join(s.directory, id, name) }

func (s *UploadSpool) recover() error {
	spoolInfo, err := os.Stat(s.directory)
	if err != nil {
		return err
	}
	spoolDevice := spoolInfo.Sys().(*syscall.Stat_t).Dev
	for _, name := range []string{"hosted", "metadata"} {
		info, err := os.Stat(filepath.Join(s.config.DataDir, name))
		if err != nil {
			return err
		}
		if info.Sys().(*syscall.Stat_t).Dev != spoolDevice {
			return errors.New("spool, hosted and metadata must share one filesystem")
		}
	}
	entries, err := os.ReadDir(s.directory)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		id, err := canonicalUploadID(entry.Name())
		if err != nil || !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("unrecognized spool entry %q; preserved for repair", entry.Name())
		}
		journal, err := readUploadJournal(s.path(id, "journal.json"), s.limits)
		if err != nil {
			return fmt.Errorf("recover upload %s: %w", id, err)
		}
		if journal.Receipt.UUID != id {
			return fmt.Errorf("journal UUID differs from directory %s", id)
		}
		job := &uploadJob{}
		job.snapshot.Store(&journal)
		s.jobs[id] = job
		children, err := os.ReadDir(s.path(id, ""))
		if err != nil {
			return err
		}
		for _, child := range children {
			if strings.HasPrefix(child.Name(), ".journal-") {
				if err := os.Remove(s.path(id, child.Name())); err != nil {
					return err
				}
			}
		}
		if err := syncDirectory(s.path(id, "")); err != nil {
			return err
		}
		if err := s.recoverInput(job); err != nil {
			return fmt.Errorf("recover upload %s: %w", id, err)
		}
		if journal.Receipt.State == "processing" || journal.Receipt.State == "verifying" {
			next := *job.snapshot.Load()
			if next.Prepared == nil {
				if journal.Receipt.State == "processing" {
					if next.Receipt.Attempt >= s.limits.Attempts {
						now := time.Now().UTC()
						next.Receipt.State = "failed"
						next.Receipt.Error = &UploadFailure{Code: "ATTEMPTS_EXHAUSTED", Message: "Interrupted processing exhausted persistent attempts", Retryable: false}
						if next.Receipt.FirstFailureAt == nil {
							next.Receipt.FirstFailureAt = &now
						}
					} else {
						next.Receipt.Attempt++
						next.Receipt.State = "verifying"
					}
				} else {
					next.Receipt.State = "verifying"
				}
			}
			if err := s.commit(job, next); err != nil {
				return err
			}
		}
	}
	for _, job := range s.jobs {
		journal := job.snapshot.Load()
		if journal.Prepared != nil && journal.Receipt.State != "ready" && journal.Receipt.State != "expired" {
			if err := s.publish(job); err != nil {
				return fmt.Errorf("recover prepared publication %s: %w", journal.Receipt.UUID, err)
			}
		}
	}
	reserved, remaining, slots := s.accounting()
	if reserved > s.limits.ReservationBytes || slots > s.limits.Slots || int64(len(s.jobs))*receiptReservationBytes > s.limits.ReceiptBytes {
		return errors.New("recovered spool exceeds configured reservations; raise limits or repair, never discard receipts")
	}
	available, err := filesystemAvailable(s.directory)
	if err != nil {
		return err
	}
	if available < remaining+s.limits.FreeFloorBytes {
		return errors.New("recovered reservations exceed filesystem free-space floor")
	}
	return nil
}

func readUploadJournal(path string, limits UploadLimits) (uploadJournal, error) {
	file, err := os.Open(path)
	if err != nil {
		return uploadJournal{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return uploadJournal{}, errors.New("journal is not a regular file")
	}
	var journal uploadJournal
	if err := decodeBoundedJSON(file, receiptReservationBytes, &journal); err != nil {
		return journal, err
	}
	if journal.JournalVersion != uploadVersion {
		return journal, errors.New("unsupported journal version")
	}
	r := journal.Receipt
	if _, err := canonicalUploadID(r.UUID); err != nil {
		return journal, err
	}
	if _, err := r.UploadDescriptor.canonical(limits); err != nil {
		return journal, err
	}
	if r.Offset < 0 || r.Offset > r.Size || r.Attempt < 1 || r.Attempt > limits.Attempts || r.CreatedAt.IsZero() || r.ProgressAt.IsZero() {
		return journal, errors.New("invalid receipt bounds")
	}
	switch r.State {
	case "receiving":
		if r.AcceptedAt != nil || journal.Prepared != nil {
			return journal, errors.New("receiving upload has accepted or prepared state")
		}
	case "verifying", "queued", "processing", "ready":
		if r.Offset != r.Size || r.AcceptedAt == nil {
			return journal, errors.New("accepted upload is incomplete")
		}
	case "failed":
		if r.Error == nil || r.FirstFailureAt == nil {
			return journal, errors.New("failed upload lacks failure checkpoint")
		}
	case "expired":
		if r.ExpiresAt == nil {
			return journal, errors.New("invalid tombstone")
		}
	default:
		return journal, errors.New("unknown receipt state")
	}
	if (r.State == "ready") != (r.Result != nil) {
		return journal, errors.New("only ready receipts may contain results")
	}
	if r.State != "expired" && r.State != "ready" && journal.Reservation != reservationFor(r.UploadDescriptor, limits) {
		return journal, errors.New("reservation differs from descriptor")
	}
	if journal.Reservation < 0 || journal.Reservation > reservationFor(r.UploadDescriptor, limits) {
		return journal, errors.New("invalid reservation")
	}
	if journal.LastChunk != nil {
		last := journal.LastChunk
		if last.Offset < 0 || last.Length <= 0 || last.Length > limits.ChunkBytes || last.Offset > r.Size-last.Length || last.Offset+last.Length != r.Offset || !validSHA256(last.SHA256) || (last.Length < limits.MinimumChunkBytes && r.Offset != r.Size) {
			return journal, errors.New("invalid last-chunk checkpoint")
		}
	} else if r.Offset != 0 {
		return journal, errors.New("committed bytes lack last-chunk checkpoint")
	}
	if journal.Prepared != nil {
		p := journal.Prepared
		if p.Metadata.ID != r.UUID || p.Result.MetadataID != r.UUID || p.Metadata.Filename != p.Result.Filename || p.Metadata.URL != p.Result.URL || p.Metadata.Size != p.Result.Size || p.Metadata.Timestamp.IsZero() || p.Result.Size <= 0 || !validSHA256(p.Result.SHA256) || (journal.Intake == nil && !strings.HasPrefix(p.Result.Filename, r.UUID+".")) || filepath.Base(p.Result.Filename) != p.Result.Filename || !isImageFile(p.Result.Filename) || p.Result.Availability != "available" || (r.Kind == "video" && (filepath.Ext(p.Result.Filename) != ".gif" || p.Result.MediaType != "image/gif" || p.Result.Size > limits.OutputBytes)) || (r.Kind == "image" && (p.Result.Size != r.Size || p.Result.SHA256 != r.SHA256)) {
			return journal, errors.New("invalid prepared publication")
		}
	}
	if r.State == "ready" && (journal.Prepared == nil || *r.Result != journal.Prepared.Result) {
		return journal, errors.New("ready receipt differs from prepared output")
	}
	return journal, nil
}

func (s *UploadSpool) recoverInput(job *uploadJob) error {
	j := *job.snapshot.Load()
	if j.Receipt.State == "ready" || j.Receipt.State == "expired" {
		if j.Receipt.State == "ready" {
			s.removeCommittedIntake(j)
		}
		return s.releasePrivateStorage(job)
	}
	input, err := os.OpenFile(s.path(j.Receipt.UUID, "input"), os.O_RDWR, 0)
	if err != nil {
		return fmt.Errorf("missing input; no zero-fill recovery: %w", err)
	}
	defer input.Close()
	info, err := input.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() < j.Receipt.Offset {
		return errors.New("input shorter than durable offset; preserved for repair")
	}
	if info.Size() > j.Receipt.Offset {
		if err := input.Truncate(j.Receipt.Offset); err != nil {
			return err
		}
		if err := input.Sync(); err != nil {
			return err
		}
	}
	if j.LastChunk != nil {
		last := j.LastChunk
		hash := sha256.New()
		if _, err := io.Copy(hash, io.NewSectionReader(input, last.Offset, last.Length)); err != nil {
			return err
		}
		if hex.EncodeToString(hash.Sum(nil)) != last.SHA256 {
			return errors.New("committed last chunk hash differs; preserved for repair")
		}
	}
	if j.Prepared != nil {
		if err := verifyFile(s.path(j.Receipt.UUID, "output"), j.Prepared.Result.Size, j.Prepared.Result.SHA256); err != nil {
			if err := verifyFile(filepath.Join(s.config.DataDir, "hosted", j.Prepared.Result.Filename), j.Prepared.Result.Size, j.Prepared.Result.SHA256); err != nil {
				return errors.New("prepared output missing or conflicting; cannot re-encode published work")
			}
		}
	}
	return nil
}

func reservationFor(d UploadDescriptor, l UploadLimits) int64 {
	reservation := d.Size + l.OverheadBytes
	if d.Kind == "video" {
		reservation += l.OutputBytes
	}
	return reservation
}

func filesystemAvailable(path string) (int64, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return 0, err
	}
	return int64(stat.Bavail) * int64(stat.Bsize), nil
}

func (s *UploadSpool) accounting() (reserved, remaining int64, slots int) {
	reserved, remaining, slots = s.transientReservations, s.transientReservations, s.transientSlots
	for _, job := range s.jobs {
		j := job.snapshot.Load()
		if j.Reservation == 0 {
			continue
		}
		reserved += j.Reservation
		slots++
		allocated := int64(0)
		var inputInfo os.FileInfo
		if info, err := os.Stat(s.path(j.Receipt.UUID, "input")); err == nil {
			inputInfo = info
			allocated += info.Size()
		}
		if info, err := os.Stat(s.path(j.Receipt.UUID, "output")); err == nil && (inputInfo == nil || !os.SameFile(info, inputInfo)) {
			allocated += info.Size()
		}
		if allocated > j.Reservation {
			allocated = j.Reservation
		}
		remaining += j.Reservation - allocated
	}
	return
}

func (s *UploadSpool) reserve(id string, descriptor UploadDescriptor) (*uploadJob, bool, error) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	if job := s.jobs[id]; job != nil {
		r := job.snapshot.Load().Receipt
		if r.State == "expired" {
			return job, false, uploadError("UPLOAD_EXPIRED", 410, "UUID has expired permanently", false)
		}
		if r.UploadDescriptor != descriptor {
			return job, false, uploadError("UUID_CONFLICT", 409, "UUID already has a different descriptor", false)
		}
		return job, false, nil
	}
	reserved, remaining, slots := s.accounting()
	reservation := reservationFor(descriptor, s.limits)
	if slots >= s.limits.Slots || reservation > s.limits.ReservationBytes-reserved || int64(len(s.jobs)+1)*receiptReservationBytes > s.limits.ReceiptBytes {
		return nil, false, uploadError("CAPACITY", 503, "live reservation or permanent receipt capacity exhausted", true)
	}
	available, err := filesystemAvailable(s.directory)
	if err != nil {
		return nil, false, uploadError("STORAGE_UNAVAILABLE", 503, "cannot inspect spool filesystem", true)
	}
	if available < remaining+reservation+s.limits.FreeFloorBytes {
		return nil, false, uploadError("CAPACITY", 503, "filesystem free-space floor would be violated", true)
	}
	directory := s.path(id, "")
	if err := os.Mkdir(directory, 0700); err != nil {
		return nil, false, uploadError("STORAGE_UNCERTAIN", 503, "UUID directory already exists or cannot be reserved", false)
	}
	now := time.Now().UTC()
	j := uploadJournal{JournalVersion: uploadVersion, Receipt: UploadReceipt{UUID: id, UploadDescriptor: descriptor, State: "receiving", Attempt: 1, CreatedAt: now, ProgressAt: now}, Reservation: reservation}
	job := &uploadJob{}
	job.snapshot.Store(&j)
	s.jobs[id] = job
	file, err := os.OpenFile(s.path(id, "input"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err == nil {
		err = file.Sync()
		closeErr := file.Close()
		if err == nil {
			err = closeErr
		}
	}
	if err == nil {
		err = s.commit(job, j)
	}
	if err == nil {
		err = syncDirectory(s.directory)
	}
	if err != nil {
		job.uncertain.Store(true)
		return job, false, uploadError("STORAGE_UNCERTAIN", 503, "reservation durability could not be confirmed; repair required", false)
	}
	return job, true, nil
}

func (s *UploadSpool) reserveTransient(size int64) (func(), error) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	reserved, remaining, slots := s.accounting()
	reservation := size + s.limits.OverheadBytes
	available, err := filesystemAvailable(s.directory)
	if err != nil {
		return nil, err
	}
	if slots >= s.limits.Slots || reservation > s.limits.ReservationBytes-reserved || available < remaining+reservation+s.limits.FreeFloorBytes {
		return nil, uploadError("CAPACITY", 503, "legacy upload would violate storage reservations", true)
	}
	s.transientReservations += reservation
	s.transientSlots++
	return func() {
		s.mutex.Lock()
		defer s.mutex.Unlock()
		s.transientReservations -= reservation
		s.transientSlots--
	}, nil
}

func (s *UploadSpool) find(id string) *uploadJob {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	return s.jobs[id]
}

func (s *UploadSpool) commit(job *uploadJob, journal uploadJournal) error {
	data, err := json.Marshal(journal)
	if err != nil {
		return err
	}
	if int64(len(data)) > receiptReservationBytes {
		return errors.New("journal exceeds permanent receipt reservation")
	}
	directory := s.path(journal.Receipt.UUID, "")
	temp, err := os.CreateTemp(directory, ".journal-")
	if err != nil {
		return err
	}
	name := temp.Name()
	defer func() { _ = temp.Close(); _ = os.Remove(name) }()
	if _, err := temp.Write(data); err != nil {
		return err
	}
	if err := temp.Sync(); err != nil {
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, filepath.Join(directory, "journal.json")); err != nil {
		job.uncertain.Store(true)
		return err
	}
	if err := syncDirectory(directory); err != nil {
		job.uncertain.Store(true)
		return err
	}
	job.snapshot.Store(&journal)
	return nil
}

func (s *UploadSpool) appendChunk(job *uploadJob, offset, length int64, digest string, body io.Reader) error {
	if !job.busy.CompareAndSwap(false, true) {
		return uploadError("BUSY", 409, "upload mutation already in progress", true)
	}
	defer job.busy.Store(false)
	if job.uncertain.Load() {
		return uploadError("STORAGE_UNCERTAIN", 503, "upload requires storage reconciliation", false)
	}
	select {
	case s.receivers <- struct{}{}:
		defer func() { <-s.receivers }()
	default:
		return uploadError("BUSY", 503, "chunk receiver capacity exhausted", true)
	}
	j := *job.snapshot.Load()
	if j.Receipt.State != "receiving" {
		return uploadError("STATE_CONFLICT", 409, "upload no longer receives chunks", false)
	}
	if offset < 0 || length <= 0 || length > s.limits.ChunkBytes || offset > j.Receipt.Size-length || (length < s.limits.MinimumChunkBytes && offset+length != j.Receipt.Size) || !validSHA256(digest) {
		return uploadError("CHUNK_CONFLICT", 400, "invalid chunk size, bounds or digest", false)
	}
	digest = strings.ToLower(digest)
	if offset != j.Receipt.Offset {
		last := j.LastChunk
		if last == nil || last.Offset != offset || last.Length != length || last.SHA256 != digest {
			return uploadError("OFFSET_CONFLICT", 409, "chunk does not append at committed offset", false)
		}
		hash := sha256.New()
		n, err := io.Copy(hash, io.LimitReader(body, length+1))
		if err != nil || n != length || hex.EncodeToString(hash.Sum(nil)) != digest {
			return uploadError("HASH_MISMATCH", 422, "replayed chunk bytes do not match checkpoint", false)
		}
		return nil
	}
	input, err := os.OpenFile(s.path(j.Receipt.UUID, "input"), os.O_WRONLY, 0)
	if err != nil {
		return uploadError("STORAGE_UNAVAILABLE", 503, "cannot open reserved input", true)
	}
	defer input.Close()
	info, err := input.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() != offset {
		job.uncertain.Store(true)
		return uploadError("STORAGE_UNCERTAIN", 503, "reserved input no longer matches committed offset; never zero-fill", false)
	}
	if _, err := input.Seek(offset, io.SeekStart); err != nil {
		return err
	}
	hash := sha256.New()
	n, writeErr := io.Copy(io.MultiWriter(input, hash), io.LimitReader(body, length+1))
	if writeErr != nil || n != length || hex.EncodeToString(hash.Sum(nil)) != digest {
		if err := input.Truncate(offset); err != nil {
			job.uncertain.Store(true)
		}
		if err := input.Sync(); err != nil {
			job.uncertain.Store(true)
		}
		if job.uncertain.Load() {
			return uploadError("STORAGE_UNCERTAIN", 503, "failed chunk rollback durability is uncertain", false)
		}
		return uploadError("HASH_MISMATCH", 422, "chunk is incomplete or hash differs", false)
	}
	if err := input.Sync(); err != nil {
		job.uncertain.Store(true)
		return uploadError("STORAGE_UNCERTAIN", 503, "input sync could not be confirmed", false)
	}
	j.Receipt.Offset = offset + length
	j.Receipt.ProgressAt = time.Now().UTC()
	j.LastChunk = &committedChunk{Offset: offset, Length: length, SHA256: digest}
	if err := s.commit(job, j); err != nil {
		if !job.uncertain.Load() {
			if err := input.Truncate(offset); err != nil {
				job.uncertain.Store(true)
			}
			if err := input.Sync(); err != nil {
				job.uncertain.Store(true)
			}
		}
		return uploadError("STORAGE_UNCERTAIN", 503, "chunk checkpoint could not be confirmed; reconcile before retry", false)
	}
	return nil
}

func (s *UploadSpool) complete(job *uploadJob) error {
	if !job.busy.CompareAndSwap(false, true) {
		return uploadError("BUSY", 409, "upload mutation already in progress", true)
	}
	defer job.busy.Store(false)
	if job.uncertain.Load() {
		return uploadError("STORAGE_UNCERTAIN", 503, "upload requires repair", false)
	}
	j := *job.snapshot.Load()
	if j.Receipt.State == "expired" {
		return uploadError("UPLOAD_EXPIRED", 410, "UUID expired permanently", false)
	}
	if j.Receipt.State != "receiving" {
		return nil
	}
	if j.Receipt.Offset != j.Receipt.Size {
		return uploadError("OFFSET_CONFLICT", 409, "input is not completely committed", false)
	}
	now := time.Now().UTC()
	j.Receipt.AcceptedAt = &now
	j.Receipt.State = "verifying"
	if err := s.commit(job, j); err != nil {
		return uploadError("STORAGE_UNCERTAIN", 503, "acceptance durability is uncertain", false)
	}
	return nil
}

func (s *UploadSpool) retry(job *uploadJob, expected int) error {
	if !job.busy.CompareAndSwap(false, true) {
		return uploadError("BUSY", 409, "upload mutation already in progress", true)
	}
	defer job.busy.Store(false)
	if job.uncertain.Load() {
		return uploadError("STORAGE_UNCERTAIN", 503, "upload requires repair", false)
	}
	j := *job.snapshot.Load()
	if expected < j.Receipt.Attempt {
		return nil
	}
	if expected > j.Receipt.Attempt {
		return uploadError("ATTEMPT_CONFLICT", 409, "expected attempt is in the future", false)
	}
	if j.Receipt.State != "failed" || j.Receipt.Error == nil || !j.Receipt.Error.Retryable || j.Receipt.Attempt >= s.limits.Attempts {
		return uploadError("STATE_CONFLICT", 409, "upload is not eligible for processor retry", false)
	}
	j.Receipt.Attempt++
	j.Receipt.State = "verifying"
	j.Receipt.Error = nil
	if err := s.commit(job, j); err != nil {
		return uploadError("STORAGE_UNCERTAIN", 503, "retry checkpoint is uncertain", false)
	}
	return nil
}

func (s *UploadSpool) releasePrivateStorage(job *uploadJob) error {
	j := *job.snapshot.Load()
	for _, name := range []string{"input", "output"} {
		if err := os.Remove(s.path(j.Receipt.UUID, name)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	if err := syncDirectory(s.path(j.Receipt.UUID, "")); err != nil {
		return err
	}
	if j.Reservation == 0 {
		return nil
	}
	j.Reservation = 0
	return s.commit(job, j)
}

func (s *UploadSpool) Start() {
	s.workers.Add(1)
	go func() { defer s.workers.Done(); s.runLocalIntake() }()
	for _, kind := range []string{"image", "video"} {
		s.workers.Add(1)
		go func() { defer s.workers.Done(); s.runExecutor(kind) }()
	}
	s.workers.Add(1)
	go func() {
		defer s.workers.Done()
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-s.ctx.Done():
				return
			case <-ticker.C:
				s.expire()
			}
		}
	}()
}

func (s *UploadSpool) jobList() []*uploadJob {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	jobs := make([]*uploadJob, 0, len(s.jobs))
	for _, job := range s.jobs {
		jobs = append(jobs, job)
	}
	return jobs
}

func (s *UploadSpool) expire() {
	for _, job := range s.jobList() {
		if !job.busy.CompareAndSwap(false, true) {
			continue
		}
		func() {
			defer job.busy.Store(false)
			if job.uncertain.Load() {
				return
			}
			j := *job.snapshot.Load()
			r := j.Receipt
			now := time.Now().UTC()
			expired := (r.State == "receiving" && (now.Sub(r.ProgressAt) > time.Duration(s.limits.ReceivingIdleSeconds)*time.Second || now.Sub(r.CreatedAt) > time.Duration(s.limits.ReceivingAbsoluteSeconds)*time.Second)) || (r.State == "failed" && r.FirstFailureAt != nil && now.Sub(*r.FirstFailureAt) > time.Duration(s.limits.FailureSeconds)*time.Second)
			if !expired {
				return
			}
			if j.Prepared != nil {
				return
			}
			j.Receipt.State = "expired"
			j.Receipt.ExpiresAt = &now
			j.Receipt.Error = &UploadFailure{Code: "UPLOAD_EXPIRED", Message: "input retention expired"}
			if err := s.commit(job, j); err != nil {
				job.uncertain.Store(true)
				return
			}
			if err := s.releasePrivateStorage(job); err != nil {
				job.uncertain.Store(true)
			}
		}()
	}
}

func verifyFile(path string, size int64, digest string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() != size {
		return errors.New("file size or type conflicts with checkpoint")
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return err
	}
	if hex.EncodeToString(hash.Sum(nil)) != digest {
		return errors.New("file hash conflicts with checkpoint")
	}
	return nil
}
