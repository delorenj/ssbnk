package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestUploadV2SharedReceiptFixtures(t *testing.T) {
	contents, err := os.ReadFile(filepath.Join("..", "clients", "protocol", "fixtures", "receipts.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixtures struct {
		Receipts []UploadReceipt `json:"receipts"`
	}
	if err := json.Unmarshal(contents, &fixtures); err != nil {
		t.Fatal(err)
	}
	if len(fixtures.Receipts) != 8 {
		t.Fatal("shared receipt fixtures missing states")
	}
	for _, receipt := range fixtures.Receipts {
		if _, err := receipt.UploadDescriptor.canonical(defaultUploadLimits()); err != nil {
			t.Fatal(err)
		}
		if (receipt.State == "ready") != (receipt.Result != nil) {
			t.Fatal("non-ready fixture invented a result")
		}
	}
}

func uploadDigest(data []byte) string {
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

func newTestSpool(t *testing.T) *UploadSpool {
	t.Helper()
	config := newIngestionConfig(t)
	spool, err := openUploadSpool(config, defaultUploadLimits())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(spool.Close)
	return spool
}

func testUploadDescriptor(data []byte) UploadDescriptor {
	return UploadDescriptor{Version: 2, OriginalName: "capture.png", Kind: "image", Size: int64(len(data)), SHA256: uploadDigest(data), CaptureTime: time.Date(2026, 10, 5, 1, 2, 3, 0, time.UTC), Profile: "original"}
}

func reserveTestUpload(t *testing.T, spool *UploadSpool, data []byte) *uploadJob {
	t.Helper()
	job, created, err := spool.reserve(uuid.NewString(), testUploadDescriptor(data))
	if err != nil || !created {
		t.Fatalf("reserve: created=%t err=%v", created, err)
	}
	return job
}

func TestUploadV2ShortFinalChunkAndReplay(t *testing.T) {
	spool := newTestSpool(t)
	data := bytes.Repeat([]byte("x"), 65536+19)
	job := reserveTestUpload(t, spool, data)
	if err := spool.appendChunk(job, 0, 19, uploadDigest(data[:19]), bytes.NewReader(data[:19])); err == nil {
		t.Fatal("short nonfinal chunk accepted")
	}
	if job.snapshot.Load().Receipt.Offset != 0 {
		t.Fatal("invalid chunk changed offset")
	}
	for _, chunk := range []struct{ offset, length int64 }{{0, 65536}, {65536, 19}} {
		body := data[chunk.offset : chunk.offset+chunk.length]
		if err := spool.appendChunk(job, chunk.offset, chunk.length, uploadDigest(body), bytes.NewReader(body)); err != nil {
			t.Fatal(err)
		}
	}
	final := data[65536:]
	if err := spool.appendChunk(job, 65536, 19, uploadDigest(final), bytes.NewReader(final)); err != nil {
		t.Fatal(err)
	}
	if err := spool.appendChunk(job, 65536, 19, uploadDigest(final), bytes.NewReader(bytes.Repeat([]byte("z"), 19))); err == nil {
		t.Fatal("spoofed replay hash accepted")
	}
	if err := spool.appendChunk(job, 0, 65536, uploadDigest(data[:65536]), bytes.NewReader(data[:65536])); err == nil {
		t.Fatal("older replay accepted")
	}
	if err := spool.complete(job); err != nil {
		t.Fatal(err)
	}
	accepted := job.snapshot.Load().Receipt.AcceptedAt
	if err := spool.complete(job); err != nil {
		t.Fatal(err)
	}
	if !accepted.Equal(*job.snapshot.Load().Receipt.AcceptedAt) || job.snapshot.Load().Receipt.State != "verifying" {
		t.Fatal("duplicate complete changed acceptance")
	}
	if job.snapshot.Load().Receipt.Result != nil {
		t.Fatal("acceptance claimed hosted readiness")
	}
}

func TestUploadV2TinyImageAndInvalidChunkBounds(t *testing.T) {
	spool := newTestSpool(t)
	job := reserveTestUpload(t, spool, testPNG)
	for _, bounds := range [][2]int64{{-1, 1}, {1, 72}, {0, 0}, {0, 73}, {1 << 62, 1 << 62}} {
		if err := spool.appendChunk(job, bounds[0], bounds[1], uploadDigest(testPNG), bytes.NewReader(testPNG)); err == nil {
			t.Fatalf("accepted bounds %v", bounds)
		}
	}
	if err := spool.appendChunk(job, 0, int64(len(testPNG)), uploadDigest(testPNG), bytes.NewReader(testPNG)); err != nil {
		t.Fatal(err)
	}
	if err := spool.complete(job); err != nil {
		t.Fatal(err)
	}
}

func TestUploadV2HashFailureRollsBackAndDoesNotRefreshExpiry(t *testing.T) {
	spool := newTestSpool(t)
	job := reserveTestUpload(t, spool, testPNG)
	before := job.snapshot.Load().Receipt.ProgressAt
	if err := spool.appendChunk(job, 0, int64(len(testPNG)), strings.Repeat("0", 64), bytes.NewReader(testPNG)); err == nil {
		t.Fatal("bad hash accepted")
	}
	info, err := os.Stat(spool.path(job.snapshot.Load().Receipt.UUID, "input"))
	if err != nil || info.Size() != 0 {
		t.Fatalf("rollback: size=%v err=%v", info, err)
	}
	if !before.Equal(job.snapshot.Load().Receipt.ProgressAt) {
		t.Fatal("bad chunk refreshed progress")
	}
}

func TestUploadV2SlowBodyDoesNotBlockStatusOrRetainMutators(t *testing.T) {
	t.Setenv("SSBNK_UPLOAD_KEY", "test-key")
	spool := newTestSpool(t)
	job := reserveTestUpload(t, spool, testPNG)
	reader, writer := io.Pipe()
	done := make(chan error, 1)
	go func() { done <- spool.appendChunk(job, 0, int64(len(testPNG)), uploadDigest(testPNG), reader) }()
	deadline := time.Now().Add(time.Second)
	for !job.busy.Load() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	id := job.snapshot.Load().Receipt.UUID
	request := httptest.NewRequest(http.MethodGet, "/api/uploads/"+id, nil)
	request.Header.Set("X-Upload-Key", "test-key")
	response := httptest.NewRecorder()
	spool.ServeHTTP(response, request)
	if response.Code != 200 {
		t.Fatalf("status while receiving body: %d", response.Code)
	}
	if err := spool.complete(job); err == nil {
		t.Fatal("simultaneous mutator accepted")
	}
	writer.Write(testPNG)
	writer.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestUploadV2LastSlotAdmissionIsAtomic(t *testing.T) {
	spool := newTestSpool(t)
	spool.limits.Slots = 1
	var wait sync.WaitGroup
	results := make(chan error, 8)
	for range 8 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			_, _, err := spool.reserve(uuid.NewString(), testUploadDescriptor(testPNG))
			results <- err
		}()
	}
	wait.Wait()
	close(results)
	successes := 0
	for err := range results {
		if err == nil {
			successes++
		}
	}
	if successes != 1 {
		t.Fatalf("last slot admitted %d jobs", successes)
	}
}

func TestUploadV2RecoveryTruncatesOnlyOverlongTail(t *testing.T) {
	for _, mutation := range []string{"overlong", "short", "missing", "future", "corrupt"} {
		t.Run(mutation, func(t *testing.T) {
			spool := newTestSpool(t)
			job := reserveTestUpload(t, spool, testPNG)
			id := job.snapshot.Load().Receipt.UUID
			if err := spool.appendChunk(job, 0, int64(len(testPNG)), uploadDigest(testPNG), bytes.NewReader(testPNG)); err != nil {
				t.Fatal(err)
			}
			config := spool.config
			spool.Close()
			switch mutation {
			case "overlong":
				file, err := os.OpenFile(spool.path(id, "input"), os.O_APPEND|os.O_WRONLY, 0)
				if err != nil {
					t.Fatal(err)
				}
				file.Write([]byte("uncommitted"))
				file.Close()
			case "short":
				if err := os.Truncate(spool.path(id, "input"), 1); err != nil {
					t.Fatal(err)
				}
			case "missing":
				if err := os.Remove(spool.path(id, "input")); err != nil {
					t.Fatal(err)
				}
			case "future":
				j := *job.snapshot.Load()
				j.JournalVersion = 3
				data, _ := json.Marshal(j)
				os.WriteFile(spool.path(id, "journal.json"), data, 0600)
			case "corrupt":
				os.WriteFile(spool.path(id, "journal.json"), []byte("{"), 0600)
			}
			recovered, err := openUploadSpool(config, defaultUploadLimits())
			if mutation != "overlong" {
				if err == nil {
					recovered.Close()
					t.Fatal("unsafe recovery accepted")
				}
				if mutation == "short" {
					info, _ := os.Stat(spool.path(id, "input"))
					if info.Size() != 1 {
						t.Fatal("short input was zero-filled")
					}
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			defer recovered.Close()
			info, err := os.Stat(recovered.path(id, "input"))
			if err != nil || info.Size() != int64(len(testPNG)) {
				t.Fatal("uncommitted tail not truncated")
			}
			if recovered.find(id).snapshot.Load().Receipt.Offset != int64(len(testPNG)) {
				t.Fatal("lost durable offset")
			}
		})
	}
}

func TestUploadV2RetryAttemptAndExpiryTombstone(t *testing.T) {
	spool := newTestSpool(t)
	job := reserveTestUpload(t, spool, testPNG)
	if err := spool.appendChunk(job, 0, int64(len(testPNG)), uploadDigest(testPNG), bytes.NewReader(testPNG)); err != nil {
		t.Fatal(err)
	}
	if err := spool.complete(job); err != nil {
		t.Fatal(err)
	}
	spool.failJob(job, errors.New("transient"))
	firstFailure := job.snapshot.Load().Receipt.FirstFailureAt
	if err := spool.retry(job, 1); err != nil {
		t.Fatal(err)
	}
	if err := spool.retry(job, 1); err != nil {
		t.Fatal("lost retry ACK duplicated attempt")
	}
	if job.snapshot.Load().Receipt.Attempt != 2 || !firstFailure.Equal(*job.snapshot.Load().Receipt.FirstFailureAt) {
		t.Fatal("retry lost persistent attempt or first failure")
	}
	if err := spool.retry(job, 3); err == nil {
		t.Fatal("future attempt accepted")
	}
	spool.failJob(job, errors.New("transient"))
	j := *job.snapshot.Load()
	old := time.Now().Add(-8 * 24 * time.Hour)
	j.Receipt.FirstFailureAt = &old
	if err := spool.commit(job, j); err != nil {
		t.Fatal(err)
	}
	spool.expire()
	if job.snapshot.Load().Receipt.State != "expired" || job.snapshot.Load().Reservation != 0 {
		t.Fatal("failed input did not become permanent tombstone")
	}
	if _, _, err := spool.reserve(j.Receipt.UUID, j.Receipt.UploadDescriptor); err == nil {
		t.Fatal("expired UUID was recreated")
	}
	if _, err := os.Stat(spool.path(j.Receipt.UUID, "input")); !os.IsNotExist(err) {
		t.Fatal("expired input retained")
	}
}

func TestUploadV2PublicationRollsForwardWithoutReencoding(t *testing.T) {
	spool := newTestSpool(t)
	job := reserveTestUpload(t, spool, testPNG)
	if err := spool.appendChunk(job, 0, int64(len(testPNG)), uploadDigest(testPNG), bytes.NewReader(testPNG)); err != nil {
		t.Fatal(err)
	}
	if err := spool.complete(job); err != nil {
		t.Fatal(err)
	}
	j := *job.snapshot.Load()
	now := time.Now().UTC()
	filename := j.Receipt.UUID + ".png"
	url := spool.config.BaseURL + "/" + filename
	j.Prepared = &preparedUpload{Metadata: ScreenshotMetadata{ID: j.Receipt.UUID, OriginalName: "capture.png", Filename: filename, URL: url, Timestamp: now, Size: int64(len(testPNG))}, Result: UploadResult{URL: url, Filename: filename, MetadataID: j.Receipt.UUID, MediaType: "image/png", Size: int64(len(testPNG)), SHA256: uploadDigest(testPNG), Availability: "available"}}
	j.Receipt.State = "processing"
	if err := os.Link(spool.path(j.Receipt.UUID, "input"), spool.path(j.Receipt.UUID, "output")); err != nil {
		t.Fatal(err)
	}
	if err := spool.commit(job, j); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(spool.path(j.Receipt.UUID, "output"), filepathJoinHosted(spool.config, filename)); err != nil {
		t.Fatal(err)
	}
	if err := spool.publish(job); err != nil {
		t.Fatal(err)
	}
	if job.snapshot.Load().Receipt.State != "ready" {
		t.Fatal("publication did not finish")
	}
	if err := spool.publish(job); err != nil {
		t.Fatal(err)
	}
	metadata, err := decodeMetadataFile(filepath.Join(spool.config.DataDir, "metadata", j.Receipt.UUID+".json"))
	if err != nil || metadata.URL != url {
		t.Fatalf("metadata: %+v %v", metadata, err)
	}
	if err := os.Remove(filepathJoinHosted(spool.config, filename)); err != nil {
		t.Fatal(err)
	}
	if spool.receipt(job).Result.Availability != "expired" {
		t.Fatal("missing hosted output remains clipboard-ready")
	}
}

func TestUploadV2HTTPAuthenticationAndDescriptorConflict(t *testing.T) {
	t.Setenv("SSBNK_UPLOAD_KEY", "test-key")
	spool := newTestSpool(t)
	id := uuid.NewString()
	descriptor := testUploadDescriptor(testPNG)
	data, _ := json.Marshal(descriptor)
	for _, test := range []struct {
		method, path, key string
		body              []byte
		status            int
	}{
		{"GET", "/api/uploads/capabilities", "", nil, 401},
		{"POST", "/api/uploads/capabilities", "test-key", nil, 405},
		{"PUT", "/api/uploads/" + id, "test-key", data, 201},
		{"PUT", "/api/uploads/" + id, "test-key", data, 200},
		{"GET", "/api/uploads/" + id, "test-key", nil, 200},
		{"GET", "/api/uploads/" + id + "/unknown", "test-key", nil, 404},
		{"GET", "/api/uploads/" + uuid.NewString(), "test-key", nil, 404},
	} {
		request := httptest.NewRequest(test.method, test.path, bytes.NewReader(test.body))
		request.Header.Set("X-Upload-Key", test.key)
		response := httptest.NewRecorder()
		spool.ServeHTTP(response, request)
		if response.Code != test.status {
			t.Fatalf("%s %s: %d %s", test.method, test.path, response.Code, response.Body.String())
		}
		if response.Header().Get("Cache-Control") != "no-store" || !json.Valid(response.Body.Bytes()) {
			t.Fatal("API response was cached or non-JSON")
		}
	}
	descriptor.OriginalName = "different.png"
	data, _ = json.Marshal(descriptor)
	request := httptest.NewRequest("PUT", "/api/uploads/"+id, bytes.NewReader(data))
	request.Header.Set("X-Upload-Key", "test-key")
	response := httptest.NewRecorder()
	spool.ServeHTTP(response, request)
	if response.Code != 409 {
		t.Fatal("UUID immutable descriptor conflict accepted")
	}
	request = httptest.NewRequest("PUT", "/api/uploads/"+id+"/chunks", bytes.NewReader(testPNG))
	request.Header.Set("X-Upload-Key", "test-key")
	request.Header.Set("Upload-Offset", "0")
	request.Header.Set("Upload-Chunk-SHA256", uploadDigest(testPNG))
	request.Header.Set("Content-Length", strconv.Itoa(len(testPNG)))
	response = httptest.NewRecorder()
	spool.ServeHTTP(response, request)
	if response.Code != 200 {
		t.Fatalf("short HTTP final chunk: %d %s", response.Code, response.Body.String())
	}
}
