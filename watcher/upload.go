package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type uploadHTTPError struct {
	status  int
	failure UploadFailure
}

func (e *uploadHTTPError) Error() string { return e.failure.Message }
func uploadError(code string, status int, message string, retryable bool) error {
	return &uploadHTTPError{status: status, failure: UploadFailure{Code: code, Message: message, Retryable: retryable}}
}

func writeUploadJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeUploadError(w http.ResponseWriter, err error, job *uploadJob) {
	failure := &uploadHTTPError{status: 503, failure: UploadFailure{Code: "STORAGE_UNAVAILABLE", Message: "upload storage unavailable", Retryable: true}}
	var known *uploadHTTPError
	if errors.As(err, &known) {
		failure = known
	}
	response := map[string]any{"version": uploadVersion, "error": failure.failure}
	if job != nil {
		response["receipt"] = job.snapshot.Load().Receipt
	}
	writeUploadJSON(w, failure.status, response)
}

func (s *UploadSpool) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	controller := http.NewResponseController(w)
	_ = controller.SetWriteDeadline(time.Now().Add(15 * time.Second))
	if strings.HasSuffix(r.URL.Path, "/chunks") {
		w.Header().Set("Connection", "close")
		_ = controller.SetWriteDeadline(time.Now().Add(75 * time.Second))
	}
	w.Header().Set("Cache-Control", "no-store")
	key := os.Getenv("SSBNK_UPLOAD_KEY")
	if key == "" {
		writeUploadError(w, uploadError("NOT_CONFIGURED", 503, "upload authentication is not configured", false), nil)
		return
	}
	presented := sha256.Sum256([]byte(r.Header.Get("X-Upload-Key")))
	expected := sha256.Sum256([]byte(key))
	if subtle.ConstantTimeCompare(presented[:], expected[:]) != 1 {
		writeUploadError(w, uploadError("UNAUTHORIZED", 401, "upload credential rejected", false), nil)
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/api/uploads")
	if path == "/capabilities" {
		if r.Method != http.MethodGet {
			writeUploadError(w, uploadError("METHOD_NOT_ALLOWED", 405, "capabilities requires GET", false), nil)
			return
		}
		_, probeErr := exec.LookPath("ffprobe")
		_, conversionErr := exec.LookPath("ffmpeg")
		writeUploadJSON(w, 200, map[string]any{"version": uploadVersion, "kinds": []string{"image", "video"}, "profiles": map[string]string{"image": "original", "video": "gif-30s-10fps-640"}, "limits": s.limits, "processing_ready": probeErr == nil && conversionErr == nil, "expiry": map[string]any{"receiving_idle_seconds": s.limits.ReceivingIdleSeconds, "receiving_absolute_seconds": s.limits.ReceivingAbsoluteSeconds, "failed_seconds": s.limits.FailureSeconds, "accepted_expires": false, "uuid_reuse": false}})
		return
	}
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	if len(parts) < 1 || len(parts) > 2 || parts[0] == "" {
		writeUploadError(w, uploadError("NOT_FOUND", 404, "unknown upload route", false), nil)
		return
	}
	id, err := canonicalUploadID(parts[0])
	if err != nil {
		writeUploadError(w, uploadError("UUID_CONFLICT", 400, err.Error(), false), nil)
		return
	}
	job := s.find(id)
	if len(parts) == 1 && r.Method == http.MethodPut {
		select {
		case s.receivers <- struct{}{}:
		default:
			writeUploadError(w, uploadError("BUSY", 503, "bounded control receivers are occupied", true), job)
			return
		}
		var descriptor UploadDescriptor
		parseErr := decodeBoundedJSON(r.Body, 8192, &descriptor)
		<-s.receivers
		if parseErr != nil {
			writeUploadError(w, uploadError("INVALID_DESCRIPTOR", 400, parseErr.Error(), false), job)
			return
		}
		descriptor, err = descriptor.canonical(s.limits)
		if err != nil {
			writeUploadError(w, uploadError("INVALID_DESCRIPTOR", 400, err.Error(), false), job)
			return
		}
		reserved, created, err := s.reserve(id, descriptor)
		if err != nil {
			writeUploadError(w, err, reserved)
			return
		}
		if reserved.uncertain.Load() {
			writeUploadError(w, uploadError("STORAGE_UNCERTAIN", 503, "reservation requires storage repair", false), reserved)
			return
		}
		status := 200
		if created {
			status = 201
		}
		writeUploadJSON(w, status, s.receipt(reserved))
		return
	}
	if len(parts) == 1 && r.Method != http.MethodGet {
		writeUploadError(w, uploadError("METHOD_NOT_ALLOWED", 405, "upload requires GET or PUT", false), job)
		return
	}
	if len(parts) == 2 && ((parts[1] == "chunks" && r.Method != http.MethodPut) || ((parts[1] == "complete" || parts[1] == "retry") && r.Method != http.MethodPost)) {
		writeUploadError(w, uploadError("METHOD_NOT_ALLOWED", 405, "method not permitted for this upload route", false), job)
		return
	}
	if len(parts) == 2 && parts[1] != "chunks" && parts[1] != "complete" && parts[1] != "retry" {
		writeUploadError(w, uploadError("NOT_FOUND", 404, "unknown upload route", false), nil)
		return
	}
	if job == nil {
		writeUploadError(w, uploadError("UPLOAD_UNKNOWN", 404, "unknown upload UUID", false), nil)
		return
	}
	if job.uncertain.Load() {
		writeUploadError(w, uploadError("STORAGE_UNCERTAIN", 503, "upload requires storage reconciliation", false), job)
		return
	}
	if job.snapshot.Load().Receipt.State == "expired" {
		writeUploadJSON(w, 410, job.snapshot.Load().Receipt)
		return
	}
	if len(parts) == 1 {
		writeUploadJSON(w, 200, s.receipt(job))
		return
	}
	switch parts[1] {
	case "chunks":
		offset, parseErr := strconv.ParseInt(r.Header.Get("Upload-Offset"), 10, 64)
		if parseErr != nil || r.ContentLength <= 0 || len(r.TransferEncoding) != 0 {
			writeUploadError(w, uploadError("CHUNK_CONFLICT", 400, "explicit positive Content-Length and Upload-Offset are required", false), job)
			return
		}
		controller := http.NewResponseController(w)
		_ = controller.SetReadDeadline(time.Now().Add(60 * time.Second))
		err = s.appendChunk(job, offset, r.ContentLength, r.Header.Get("Upload-Chunk-SHA256"), r.Body)
		_ = controller.SetWriteDeadline(time.Now().Add(15 * time.Second))
	case "complete":
		if r.ContentLength != 0 {
			writeUploadError(w, uploadError("INVALID_REQUEST", 400, "complete requires an empty body", false), job)
			return
		}
		err = s.complete(job)
	case "retry":
		var request struct {
			ExpectedAttempt int `json:"expectedAttempt"`
		}
		if parseErr := decodeBoundedJSON(r.Body, 8192, &request); parseErr != nil || request.ExpectedAttempt < 1 {
			writeUploadError(w, uploadError("ATTEMPT_CONFLICT", 400, "expectedAttempt must be a positive integer", false), job)
			return
		}
		err = s.retry(job, request.ExpectedAttempt)
	}
	if err != nil {
		writeUploadError(w, err, job)
		return
	}
	status := 200
	if parts[1] == "complete" || parts[1] == "retry" {
		status = 202
	}
	writeUploadJSON(w, status, s.receipt(job))
}

func (s *UploadSpool) receipt(job *uploadJob) UploadReceipt {
	r := job.snapshot.Load().Receipt
	if r.Result == nil {
		return r
	}
	result := *r.Result
	if info, err := os.Stat(filepathJoinHosted(s.config, result.Filename)); err != nil || !info.Mode().IsRegular() || info.Size() != result.Size {
		result.Availability = "expired"
	}
	if info, err := os.Stat(filepath.Join(s.config.DataDir, "metadata", result.MetadataID+".json")); err != nil || !info.Mode().IsRegular() {
		result.Availability = "expired"
	}
	r.Result = &result
	return r
}
