package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestWithHeadersSetsCachePolicy(t *testing.T) {
	tests := []struct {
		name string
		path string
		want string
	}{
		{name: "html shell", path: "/", want: "no-cache"},
		{name: "client route", path: "/gallery", want: "no-cache"},
		{name: "fingerprinted asset", path: "/_astro/gallery.abc123.js", want: "public, max-age=31536000, immutable"},
		{name: "gallery api", path: "/api/screenshots", want: "no-store"},
		{name: "health", path: "/health", want: "no-store"},
		{name: "latest redirect", path: "/latest/2", want: "no-store"},
		{name: "hosted image", path: "/capture.png", want: "public, max-age=86400, immutable"},
	}

	handler := withHeaders(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, tt.path, nil))

			if got := recorder.Header().Get("Cache-Control"); got != tt.want {
				t.Fatalf("Cache-Control = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestGIFScreenshotPreservesGIFContentAndExtension(t *testing.T) {
	root := t.TempDir()
	config := Config{
		ScreenshotDir: filepath.Join(root, "screenshots"),
		ScreencastDir: filepath.Join(root, "screencasts"),
		DataDir:       filepath.Join(root, "data"),
		StateDir:      filepath.Join(root, "state"),
		BaseURL:       "http://test.local",
	}
	for _, dir := range []string{
		config.ScreenshotDir,
		config.ScreencastDir,
		filepath.Join(config.DataDir, "hosted"),
		filepath.Join(config.DataDir, "metadata"),
	} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			t.Fatal(err)
		}
	}

	gif := append([]byte("GIF89a"), bytes.Repeat([]byte{0}, 64)...)
	source := filepath.Join(config.ScreenshotDir, "capture.gif")
	if err := os.WriteFile(source, gif, 0644); err != nil {
		t.Fatal(err)
	}
	if err := processScreenshot(source, config); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(source); !os.IsNotExist(err) {
		t.Fatalf("source was not removed after commit: %v", err)
	}

	hosted, err := os.ReadDir(filepath.Join(config.DataDir, "hosted"))
	if err != nil || len(hosted) != 1 {
		t.Fatalf("hosted entries = %d, %v", len(hosted), err)
	}
	if filepath.Ext(hosted[0].Name()) != ".gif" {
		t.Fatalf("hosted GIF was mislabeled: %s", hosted[0].Name())
	}
	stored, err := os.ReadFile(filepath.Join(config.DataDir, "hosted", hosted[0].Name()))
	if err != nil || !bytes.Equal(stored, gif) {
		t.Fatalf("stored GIF changed: %v", err)
	}
}
