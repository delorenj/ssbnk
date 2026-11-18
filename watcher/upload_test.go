package main

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var testPNG = func() []byte {
	var data bytes.Buffer
	img := image.NewNRGBA(image.Rect(0, 0, 2, 2))
	img.Set(0, 0, color.Black)
	if err := png.Encode(&data, img); err != nil {
		panic(err)
	}
	return data.Bytes()
}()

func assertDecodablePNG(t *testing.T, contents []byte) {
	t.Helper()
	decoded, err := png.Decode(bytes.NewReader(contents))
	if err != nil {
		t.Fatalf("hosted PNG cannot be decoded: %v", err)
	}
	if decoded.Bounds() != image.Rect(0, 0, 2, 2) {
		t.Fatalf("unexpected PNG bounds: %v", decoded.Bounds())
	}
}

func TestUploadAcceptsSniffedImageAndWritesMetadata(t *testing.T) {
	t.Setenv("SSBNK_UPLOAD_KEY", "test-upload-key")
	config, _ := createTestConfig(t)
	req := newMultipartUploadRequest(t, "misleading.txt", testPNG, "test-upload-key")
	recorder := httptest.NewRecorder()

	handleUpload(recorder, req, config)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
	var response map[string]string
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if filepath.Ext(response["filename"]) != ".png" {
		t.Fatalf("server did not derive PNG extension from bytes: %#v", response)
	}
	hostedPath := filepath.Join(config.DataDir, "hosted", response["filename"])
	contents, err := os.ReadFile(hostedPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(contents, testPNG) {
		t.Fatal("stored upload differs from request bytes")
	}
	assertDecodablePNG(t, contents)
	metadataEntries, err := os.ReadDir(filepath.Join(config.DataDir, "metadata"))
	if err != nil || len(metadataEntries) != 1 {
		t.Fatalf("metadata entries = %d, %v", len(metadataEntries), err)
	}
}

func TestUploadPublishesHostFilenameAndURL(t *testing.T) {
	t.Setenv("SSBNK_UPLOAD_KEY", "test-upload-key")
	config, _ := createTestConfig(t)
	req := newMultipartUploadRequest(t, "remote.png", testPNG, "test-upload-key")
	recorder := httptest.NewRecorder()
	handleUpload(recorder, req, config)
	if recorder.Code != http.StatusOK {
		t.Fatalf("upload status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
	var response map[string]string
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	filename, err := readMarker(filepath.Join(config.StateDir, lastScreenshotMarker))
	if err != nil || filename != response["filename"] || filepath.Base(filename) != filename {
		t.Fatalf("host marker = %q (%v), response = %#v", filename, err, response)
	}
	contents, err := os.ReadFile(filepath.Join(config.DataDir, "hosted", filename))
	if err != nil || !bytes.Equal(contents, testPNG) {
		t.Fatalf("hosted image missing or different: %v", err)
	}
	assertDecodablePNG(t, contents)
	url, err := readMarker(filepath.Join(config.StateDir, latestURLMarker))
	if err != nil || url != response["url"] || url != config.BaseURL+"/"+filename {
		t.Fatalf("host URL marker = %q (%v), response = %#v", url, err, response)
	}
}

func TestUploadRejectsSpoofedImageWithoutCreatingFiles(t *testing.T) {
	t.Setenv("SSBNK_UPLOAD_KEY", "test-upload-key")
	config, _ := createTestConfig(t)
	req := newMultipartUploadRequest(t, "not-really.png", []byte("plain text"), "test-upload-key")
	recorder := httptest.NewRecorder()

	handleUpload(recorder, req, config)
	if recorder.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
	assertDirectoryEmpty(t, filepath.Join(config.DataDir, "hosted"))
	assertDirectoryEmpty(t, filepath.Join(config.DataDir, "metadata"))
}

func TestUploadRejectsOversizedBodyWith413(t *testing.T) {
	t.Setenv("SSBNK_UPLOAD_KEY", "test-upload-key")
	config, _ := createTestConfig(t)
	largePNG := append(append([]byte(nil), testPNG...), bytes.Repeat([]byte{0}, 2048)...)
	req := newMultipartUploadRequest(t, "large.png", largePNG, "test-upload-key")
	recorder := httptest.NewRecorder()

	handleUploadWithLimits(recorder, req, config, 1024, 1280)
	if recorder.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
	assertDirectoryEmpty(t, filepath.Join(config.DataDir, "hosted"))
	assertDirectoryEmpty(t, filepath.Join(config.DataDir, "metadata"))
}

func TestUploadRejectsOversizedFileAndRemovesPartialDestination(t *testing.T) {
	t.Setenv("SSBNK_UPLOAD_KEY", "test-upload-key")
	config, _ := createTestConfig(t)
	largePNG := append(append([]byte(nil), testPNG...), bytes.Repeat([]byte{0}, 2048)...)
	req := newMultipartUploadRequest(t, "large.png", largePNG, "test-upload-key")
	recorder := httptest.NewRecorder()

	// The multipart body fits, but the file itself exceeds its independent cap.
	handleUploadWithLimits(recorder, req, config, 1024, 4096)
	if recorder.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
	assertDirectoryEmpty(t, filepath.Join(config.DataDir, "hosted"))
	assertDirectoryEmpty(t, filepath.Join(config.DataDir, "metadata"))
}

func TestUploadMetadataFailureRemovesPartialImage(t *testing.T) {
	t.Setenv("SSBNK_UPLOAD_KEY", "test-upload-key")
	root := t.TempDir()
	dataDir := filepath.Join(root, "data")
	if err := os.MkdirAll(filepath.Join(dataDir, "hosted"), 0755); err != nil {
		t.Fatal(err)
	}
	// A regular file where the metadata directory must be guarantees metadata
	// persistence fails even when the test runs as root.
	if err := os.WriteFile(filepath.Join(dataDir, "metadata"), []byte("blocked"), 0644); err != nil {
		t.Fatal(err)
	}
	config := Config{DataDir: dataDir, StateDir: filepath.Join(dataDir, "state"), BaseURL: "https://ss.test"}
	req := newMultipartUploadRequest(t, "shot.png", testPNG, "test-upload-key")
	recorder := httptest.NewRecorder()

	handleUpload(recorder, req, config)
	if recorder.Code != http.StatusInternalServerError || !strings.Contains(recorder.Body.String(), "metadata") {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
	assertDirectoryEmpty(t, filepath.Join(dataDir, "hosted"))
}

func TestUploadUsesConstantTimeCredentialCheckBehavior(t *testing.T) {
	t.Setenv("SSBNK_UPLOAD_KEY", "correct-key")
	config, _ := createTestConfig(t)
	for _, key := range []string{"wrong-key", "", "correct-key-with-suffix"} {
		req := newMultipartUploadRequest(t, "shot.png", testPNG, key)
		recorder := httptest.NewRecorder()
		handleUpload(recorder, req, config)
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("key %q: status = %d", key, recorder.Code)
		}
	}
}

func newMultipartUploadRequest(t *testing.T, filename string, contents []byte, key string) *http.Request {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", filename)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(part, bytes.NewReader(contents)); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/upload", &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.Header.Set("X-Upload-Key", key)
	return req
}

func assertDirectoryEmpty(t *testing.T, path string) {
	t.Helper()
	entries, err := os.ReadDir(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		names := make([]string, 0, len(entries))
		for _, entry := range entries {
			names = append(names, entry.Name())
		}
		t.Fatalf("expected %s to be empty, found %v", path, names)
	}
}
