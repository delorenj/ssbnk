package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type boundedMediaBuffer struct {
	mutex    sync.Mutex
	buffer   bytes.Buffer
	limit    int
	overflow bool
}

func (b *boundedMediaBuffer) Write(p []byte) (int, error) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	length := len(p)
	remaining := b.limit - b.buffer.Len()
	if len(p) > remaining {
		b.overflow = true
		p = p[:remaining]
	}
	_, _ = b.buffer.Write(p)
	return length, nil
}

func (b *boundedMediaBuffer) Bytes() []byte {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	return append([]byte(nil), b.buffer.Bytes()...)
}

type mediaProbe struct {
	Streams []struct {
		CodecType string `json:"codec_type"`
		Width     int    `json:"width"`
		Height    int    `json:"height"`
	} `json:"streams"`
}

func runMediaLauncher(args []string) error {
	if len(args) < 4 {
		return errors.New("internal media launcher requires memory, output bound and executable")
	}
	memory, err := strconv.ParseUint(args[0], 10, 64)
	if err != nil || memory < 64<<20 {
		return errors.New("invalid child memory bound")
	}
	fileSize, err := strconv.ParseUint(args[1], 10, 64)
	if err != nil || fileSize == 0 {
		return errors.New("invalid child output bound")
	}
	if args[2] != "ffmpeg" && args[2] != "ffprobe" {
		return errors.New("internal launcher only permits media tools")
	}
	path, err := exec.LookPath(args[2])
	if err != nil {
		return err
	}
	if err := syscall.Setrlimit(syscall.RLIMIT_AS, &syscall.Rlimit{Cur: memory, Max: memory}); err != nil {
		return fmt.Errorf("set media address-space limit: %w", err)
	}
	if err := syscall.Setrlimit(syscall.RLIMIT_FSIZE, &syscall.Rlimit{Cur: fileSize, Max: fileSize}); err != nil {
		return fmt.Errorf("set media file-size limit: %w", err)
	}
	return syscall.Exec(path, args[2:], os.Environ())
}

func runContainedMedia(ctx context.Context, memory uint64, outputLimit int64, directory, tool string, args ...string) ([]byte, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	launcherArgs := append([]string{"internal-media", strconv.FormatUint(memory, 10), strconv.FormatInt(outputLimit, 10), tool}, args...)
	cmd := exec.CommandContext(ctx, executable, launcherArgs...)
	cmd.Env = append(os.Environ(), "TMPDIR="+directory, "OMP_NUM_THREADS=2", "OPENBLAS_NUM_THREADS=2")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 2 * time.Second
	stdout := &boundedMediaBuffer{limit: 64 << 10}
	stderr := &boundedMediaBuffer{limit: 16 << 10}
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		return nil, uploadError("MEDIA_RESOURCE_LIMIT", 422, "media tool could not start under containment", false)
	}
	finished := make(chan error, 1)
	go func() { finished <- cmd.Wait() }()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	var executionErr error
	resourceExceeded := false
monitor:
	for {
		select {
		case executionErr = <-finished:
			break monitor
		case <-ticker.C:
			entries, err := os.ReadDir(directory)
			if err != nil {
				resourceExceeded = true
			} else {
				var scratch int64
				for _, entry := range entries {
					if entry.Name() == "input" || entry.Name() == "journal.json" || strings.HasPrefix(entry.Name(), ".journal-") {
						continue
					}
					info, err := entry.Info()
					if err != nil || !info.Mode().IsRegular() {
						resourceExceeded = true
						break
					}
					if entry.Name() == "output" {
						if info.Size() > outputLimit {
							resourceExceeded = true
						}
						continue
					}
					scratch += info.Size()
				}
				if scratch > 16<<20 {
					resourceExceeded = true
				}
			}
			if resourceExceeded {
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
				executionErr = <-finished
				break monitor
			}
		}
	}
	if resourceExceeded {
		return nil, uploadError("MEDIA_RESOURCE_LIMIT", 422, "media output or scratch exceeded the production bound", false)
	}
	if executionErr != nil {
		if ctx.Err() != nil {
			return nil, uploadError("MEDIA_TIMEOUT", 422, "media execution deadline exceeded", false)
		}
		return nil, uploadError("MEDIA_RESOURCE_LIMIT", 422, "media tool rejected input or exceeded its resource ceiling", false)
	}
	if stdout.overflow {
		return nil, uploadError("MEDIA_RESOURCE_LIMIT", 422, "media probe exceeded bounded output", false)
	}
	return stdout.Bytes(), nil
}

func probeUpload(ctx context.Context, input, directory string, descriptor UploadDescriptor, limits UploadLimits) error {
	data, err := runContainedMedia(ctx, limits.ProbeMemoryBytes, 16<<20, directory, "ffprobe", "-v", "error", "-threads", "2", "-show_entries", "stream=codec_type,width,height", "-of", "json", input)
	if err != nil {
		return err
	}
	var probe mediaProbe
	if err := json.Unmarshal(data, &probe); err != nil {
		return uploadError("UNSUPPORTED_MEDIA", 422, "media probe returned invalid stream information", false)
	}
	for _, stream := range probe.Streams {
		if stream.CodecType != "video" {
			continue
		}
		if stream.Width <= 0 || stream.Height <= 0 || stream.Width > limits.Dimension || stream.Height > limits.Dimension || int64(stream.Width)*int64(stream.Height) > limits.Pixels {
			return uploadError("MEDIA_RESOURCE_LIMIT", 422, "source dimensions exceed limits", false)
		}
		if descriptor.Kind == "video" {
			height := int64(math.Ceil(float64(stream.Height) * 640 / float64(stream.Width)))
			if height > int64(limits.ResultHeight) || height*640 > limits.ResultPixels {
				return uploadError("UNSUPPORTED_MEDIA", 422, "aspect ratio exceeds fixed GIF profile", false)
			}
		}
		return nil
	}
	return uploadError("UNSUPPORTED_MEDIA", 422, "input contains no supported visual stream", false)
}

func (s *UploadSpool) runExecutor(kind string) {
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
		}
		for _, job := range s.jobList() {
			j := job.snapshot.Load()
			if j.Receipt.Kind != kind || (j.Receipt.State != "verifying" && j.Receipt.State != "queued" && j.Prepared == nil) || j.Receipt.State == "ready" || j.Receipt.State == "expired" || job.uncertain.Load() {
				continue
			}
			if !job.busy.CompareAndSwap(false, true) {
				continue
			}
			err := s.prepare(job)
			job.busy.Store(false)
			if err == nil {
				err = s.publish(job)
			}
			if err != nil {
				var busy *uploadHTTPError
				if !errors.As(err, &busy) || busy.failure.Code != "BUSY" {
					s.failJob(job, err)
				}
			}
			if s.ctx.Err() != nil {
				return
			}
		}
	}
}

func (s *UploadSpool) prepare(job *uploadJob) error {
	j := *job.snapshot.Load()
	if j.Prepared != nil {
		return nil
	}
	input := s.path(j.Receipt.UUID, "input")
	directory := s.path(j.Receipt.UUID, "")
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.limits.VerificationSeconds)*time.Second)
	defer cancel()
	if err := verifyFileContext(ctx, input, j.Receipt.Size, j.Receipt.SHA256); err != nil {
		return uploadError("HASH_MISMATCH", 422, "full input hash differs from descriptor", false)
	}
	extension := ".gif"
	if j.Receipt.Kind == "image" {
		file, err := os.Open(input)
		if err != nil {
			return err
		}
		extension, err = sniffImageExtension(file, filepath.Ext(j.Receipt.OriginalName))
		file.Close()
		if err != nil {
			return uploadError("UNSUPPORTED_MEDIA", 422, "input is not a supported image", false)
		}
	}
	if err := probeUpload(ctx, input, directory, j.Receipt.UploadDescriptor, s.limits); err != nil {
		return err
	}
	j.Receipt.State = "queued"
	if err := s.commit(job, j); err != nil {
		return err
	}
	j.Receipt.State = "processing"
	if err := s.commit(job, j); err != nil {
		return err
	}
	output := s.path(j.Receipt.UUID, "output")
	if err := os.Remove(output); err != nil && !os.IsNotExist(err) {
		return err
	}
	if j.Receipt.Kind == "image" {
		if err := os.Link(input, output); err != nil {
			return err
		}
	} else {
		conversionCtx, cancel := context.WithTimeout(s.ctx, time.Duration(s.limits.ConversionSeconds)*time.Second)
		args := []string{"-nostdin", "-v", "error", "-y", "-threads", "2", "-filter_threads", "2", "-filter_complex_threads", "2", "-i", input, "-t", "30", "-vf", "fps=10,scale=640:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse", "-threads", "2", "-loop", "0", "-f", "gif", output}
		_, err := runContainedMedia(conversionCtx, s.limits.ConversionMemoryBytes, s.limits.OutputBytes, directory, "ffmpeg", args...)
		cancel()
		if err != nil {
			return err
		}
		if err := validateGIF(output); err != nil {
			return uploadError("UNSUPPORTED_MEDIA", 422, "conversion did not produce a valid GIF", false)
		}
	}
	file, err := os.OpenFile(output, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer file.Close()
	if err := file.Chmod(0644); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := syncDirectory(directory); err != nil {
		return err
	}
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if info.Size() <= 0 || (j.Receipt.Kind == "video" && info.Size() > s.limits.OutputBytes) {
		return uploadError("MEDIA_RESOURCE_LIMIT", 422, "output exceeds reservation", false)
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return err
	}
	filename := j.Receipt.UUID + extension
	url := strings.TrimRight(s.config.BaseURL, "/") + "/" + filename
	now := time.Now().UTC()
	mediaType := map[string]string{".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp"}[extension]
	result := UploadResult{URL: url, Filename: filename, MetadataID: j.Receipt.UUID, MediaType: mediaType, Size: info.Size(), SHA256: hex.EncodeToString(hash.Sum(nil)), Availability: "available"}
	metadata := ScreenshotMetadata{ID: j.Receipt.UUID, OriginalName: j.Receipt.OriginalName, Filename: filename, URL: url, Timestamp: now, Size: info.Size()}
	return s.checkpointPrepared(job, j, extension, result, metadata)
}

func (s *UploadSpool) failJob(job *uploadJob, err error) {
	if s.ctx.Err() != nil || job.uncertain.Load() || !job.busy.CompareAndSwap(false, true) {
		return
	}
	defer job.busy.Store(false)
	j := *job.snapshot.Load()
	if j.Receipt.State == "ready" {
		return
	}
	failure := UploadFailure{Code: "STORAGE_UNAVAILABLE", Message: "processor storage unavailable", Retryable: true}
	var known *uploadHTTPError
	if errors.As(err, &known) {
		failure = known.failure
	}
	if failure.Code == "STORAGE_UNCERTAIN" {
		job.uncertain.Store(true)
		return
	}
	if j.Prepared != nil {
		job.uncertain.Store(true)
		return
	}
	j.Receipt.State = "failed"
	j.Receipt.Error = &failure
	if j.Receipt.FirstFailureAt == nil {
		now := time.Now().UTC()
		j.Receipt.FirstFailureAt = &now
	}
	if j.Receipt.Attempt >= s.limits.Attempts {
		j.Receipt.Error.Retryable = false
	}
	if err := s.commit(job, j); err != nil {
		job.uncertain.Store(true)
	}
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}
func verifyFileContext(ctx context.Context, path string, size int64, digest string) error {
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
		return errors.New("input size differs")
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, contextReader{ctx: ctx, reader: file}); err != nil {
		return err
	}
	if hex.EncodeToString(hash.Sum(nil)) != digest {
		return errors.New("input hash differs")
	}
	return nil
}
