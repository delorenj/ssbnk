package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWriteIngestionStateAtomicallyPublishesBothMarkers(t *testing.T) {
	stateDir := t.TempDir()
	if err := writeIngestionState(stateDir, "shot.png", "https://ss.test/shot.png"); err != nil {
		t.Fatal(err)
	}
	last, err := readMarker(filepath.Join(stateDir, lastScreenshotMarker))
	if err != nil || last != "shot.png" {
		t.Fatalf("last marker = %q, %v", last, err)
	}
	latest, err := readMarker(filepath.Join(stateDir, latestURLMarker))
	if err != nil || latest != "https://ss.test/shot.png" {
		t.Fatalf("latest marker = %q, %v", latest, err)
	}
	entries, err := os.ReadDir(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.Contains(entry.Name(), ".tmp-") {
			t.Fatalf("temporary marker leaked: %s", entry.Name())
		}
	}

	if err := writeIngestionState(stateDir, "../escape.png", "https://ss.test/escape.png"); err == nil {
		t.Fatal("expected unsafe filename to be rejected")
	}
}

func TestStateFailureDoesNotFailScreenshotIngestion(t *testing.T) {
	root := t.TempDir()
	config := Config{
		ScreenshotDir: filepath.Join(root, "screenshots"),
		ScreencastDir: filepath.Join(root, "screencasts"),
		DataDir:       filepath.Join(root, "data"),
		StateDir:      filepath.Join(root, "not-a-directory", "state"),
		BaseURL:       "https://ss.test",
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
	if err := os.WriteFile(filepath.Join(root, "not-a-directory"), []byte("block mkdir"), 0644); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(config.ScreenshotDir, "source.png")
	if err := os.WriteFile(source, testPNG, 0644); err != nil {
		t.Fatal(err)
	}

	if err := processScreenshot(source, config); err != nil {
		t.Fatalf("state failure leaked into ingestion: %v", err)
	}
	files, err := os.ReadDir(filepath.Join(config.DataDir, "hosted"))
	if err != nil || len(files) != 1 {
		t.Fatalf("hosted files = %d, %v", len(files), err)
	}
}

func TestClipboardBridgeConsumesAtomicURLMarkers(t *testing.T) {
	stateDir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	copied := make(chan string, 4)
	errorsCh := make(chan error, 1)
	go func() {
		errorsCh <- runClipboardBridge(ctx, ClipboardBridgeOptions{
			StateDir:     stateDir,
			PollInterval: 10 * time.Millisecond,
			Copy: func(_ context.Context, text string) error {
				copied <- text
				return nil
			},
		})
	}()

	if err := writeIngestionState(stateDir, "one.png", "https://ss.test/one.png"); err != nil {
		t.Fatal(err)
	}
	wantCopiedURL(t, copied, "https://ss.test/one.png")
	if err := writeIngestionState(stateDir, "two.png", "https://ss.test/two.png"); err != nil {
		t.Fatal(err)
	}
	wantCopiedURL(t, copied, "https://ss.test/two.png")

	cancel()
	select {
	case err := <-errorsCh:
		if err != nil {
			t.Fatalf("bridge shutdown: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("clipboard bridge did not stop after context cancellation")
	}
}

func TestClipboardBridgeRetriesFailedCopyViaPolling(t *testing.T) {
	stateDir := t.TempDir()
	if err := writeIngestionState(stateDir, "retry.png", "https://ss.test/retry.png"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	attempts := make(chan string, 4)
	attempt := 0
	done := make(chan error, 1)
	go func() {
		done <- runClipboardBridge(ctx, ClipboardBridgeOptions{
			StateDir:     stateDir,
			PollInterval: 10 * time.Millisecond,
			Copy: func(_ context.Context, text string) error {
				attempt++
				attempts <- text
				if attempt == 1 {
					return errors.New("temporary compositor failure")
				}
				return nil
			},
		})
	}()
	wantCopiedURL(t, attempts, "https://ss.test/retry.png")
	wantCopiedURL(t, attempts, "https://ss.test/retry.png")
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func wantCopiedURL(t *testing.T, copied <-chan string, want string) {
	t.Helper()
	select {
	case got := <-copied:
		if got != want {
			t.Fatalf("copied URL = %q, want %q", got, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for clipboard URL %q", want)
	}
}
