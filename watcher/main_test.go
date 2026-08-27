package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

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
