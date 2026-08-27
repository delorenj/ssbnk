package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

var (
	testJPEG = append([]byte{0xff, 0xd8, 0xff, 0xe0}, bytes.Repeat([]byte{0}, 64)...)
	testGIF  = append([]byte("GIF89a"), bytes.Repeat([]byte{0}, 64)...)
	testWebP = append([]byte("RIFF\x10\x00\x00\x00WEBPVP8 "), bytes.Repeat([]byte{0}, 64)...)
)

func TestWatchedImageExtensionComesFromContent(t *testing.T) {
	tests := []struct {
		name     string
		source   string
		contents []byte
		wantExt  string
	}{
		{name: "PNG", source: "capture.jpg", contents: testPNG, wantExt: ".png"},
		{name: "JPEG", source: "capture.png", contents: testJPEG, wantExt: ".jpg"},
		{name: "GIF", source: "capture.png", contents: testGIF, wantExt: ".gif"},
		{name: "WebP", source: "capture.png", contents: testWebP, wantExt: ".webp"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			config := newIngestionConfig(t)
			source := filepath.Join(config.ScreenshotDir, test.source)
			if err := os.WriteFile(source, test.contents, 0644); err != nil {
				t.Fatal(err)
			}
			if err := processScreenshot(source, config); err != nil {
				t.Fatal(err)
			}

			hosted := regularFileNames(t, filepath.Join(config.DataDir, "hosted"))
			if len(hosted) != 1 || filepath.Ext(hosted[0]) != test.wantExt {
				t.Fatalf("hosted files = %v, want extension %s", hosted, test.wantExt)
			}
			stored, err := os.ReadFile(filepath.Join(config.DataDir, "hosted", hosted[0]))
			if err != nil || !bytes.Equal(stored, test.contents) {
				t.Fatalf("stored bytes changed: %v", err)
			}
		})
	}
}

func TestWatchedImageMetadataFailureRollsBackAssetAndKeepsSource(t *testing.T) {
	root := t.TempDir()
	dataDir := filepath.Join(root, "data")
	if err := os.MkdirAll(filepath.Join(dataDir, "hosted"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dataDir, "metadata"), []byte("not a directory"), 0644); err != nil {
		t.Fatal(err)
	}
	screenshotDir := filepath.Join(root, "screenshots")
	if err := os.MkdirAll(screenshotDir, 0755); err != nil {
		t.Fatal(err)
	}
	config := Config{
		ScreenshotDir: screenshotDir,
		DataDir:       dataDir,
		StateDir:      filepath.Join(root, "state"),
		BaseURL:       "https://ss.test",
	}
	source := filepath.Join(screenshotDir, "capture.png")
	if err := os.WriteFile(source, testPNG, 0644); err != nil {
		t.Fatal(err)
	}

	err := processScreenshot(source, config)
	if err == nil || !strings.Contains(err.Error(), "metadata") {
		t.Fatalf("expected metadata failure, got %v", err)
	}
	assertPathExists(t, source)
	assertDirectoryEmpty(t, filepath.Join(dataDir, "hosted"))
	assertPathMissing(t, filepath.Join(config.StateDir, latestURLMarker))
}

func TestHostedDestinationReservationIsConcurrentAndCollisionSafe(t *testing.T) {
	config := newIngestionConfig(t)
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	hostedDir := filepath.Join(config.DataDir, "hosted")
	basePath := filepath.Join(hostedDir, "20260827-1200.png")
	if err := os.WriteFile(basePath, []byte("preexisting"), 0644); err != nil {
		t.Fatal(err)
	}

	const workers = 8
	var wait sync.WaitGroup
	errorsCh := make(chan error, workers)
	for worker := 0; worker < workers; worker++ {
		worker := worker
		wait.Add(1)
		go func() {
			defer wait.Done()
			contents := []byte(fmt.Sprintf("worker-%d", worker))
			_, _, err := storeHostedAsset(bytes.NewReader(contents), fmt.Sprintf("worker-%d.png", worker), ".png", now, config)
			errorsCh <- err
		}()
	}
	wait.Wait()
	close(errorsCh)
	for err := range errorsCh {
		if err != nil {
			t.Fatal(err)
		}
	}

	baseContents, err := os.ReadFile(basePath)
	if err != nil || string(baseContents) != "preexisting" {
		t.Fatalf("preexisting destination was overwritten: %q, %v", baseContents, err)
	}
	hosted := regularFileNames(t, hostedDir)
	if len(hosted) != workers+1 {
		t.Fatalf("hosted file count = %d, want %d: %v", len(hosted), workers+1, hosted)
	}
	metadata := regularFileNames(t, filepath.Join(config.DataDir, "metadata"))
	if len(metadata) != workers {
		t.Fatalf("metadata file count = %d, want %d", len(metadata), workers)
	}
}

func TestVideoRetrySuccessClearsPriorErrorAndUsesUniqueNames(t *testing.T) {
	config := newIngestionConfig(t)
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	basePath := filepath.Join(config.DataDir, "hosted", "20260827-1200.gif")
	if err := os.WriteFile(basePath, []byte("preexisting"), 0644); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(config.ScreencastDir, "recording.webm")
	if err := os.WriteFile(source, []byte("video"), 0644); err != nil {
		t.Fatal(err)
	}

	attempts := 0
	var tempPaths []string
	converter := func(_, destination string, explicit bool) ([]byte, error) {
		if explicit {
			t.Fatal("explicit format fallback should not be needed after standard retry succeeds")
		}
		attempts++
		tempPaths = append(tempPaths, destination)
		if attempts == 1 {
			return []byte("first failure"), errors.New("transient conversion error")
		}
		return nil, os.WriteFile(destination, testGIF, 0644)
	}
	if err := processVideoWithConverter(source, config, now, 0, converter); err != nil {
		t.Fatalf("later successful retry retained stale error: %v", err)
	}
	if attempts != 2 {
		t.Fatalf("conversion attempts = %d, want 2", attempts)
	}
	assertPathMissing(t, source)
	baseContents, err := os.ReadFile(basePath)
	if err != nil || string(baseContents) != "preexisting" {
		t.Fatalf("preexisting hosted GIF was overwritten: %q, %v", baseContents, err)
	}
	if _, err := os.Stat(filepath.Join(config.DataDir, "hosted", "20260827-1200-1.gif")); err != nil {
		t.Fatalf("unique hosted GIF missing: %v", err)
	}
	for _, tempPath := range tempPaths {
		assertPathMissing(t, tempPath)
	}
}

func TestVideoMetadataFailureRollsBackGIFAndKeepsSource(t *testing.T) {
	root := t.TempDir()
	dataDir := filepath.Join(root, "data")
	hostedDir := filepath.Join(dataDir, "hosted")
	screencastDir := filepath.Join(root, "screencasts")
	for _, directory := range []string{hostedDir, screencastDir} {
		if err := os.MkdirAll(directory, 0755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dataDir, "metadata"), []byte("not a directory"), 0644); err != nil {
		t.Fatal(err)
	}
	config := Config{
		ScreencastDir: screencastDir,
		DataDir:       dataDir,
		StateDir:      filepath.Join(root, "state"),
		BaseURL:       "https://ss.test",
	}
	source := filepath.Join(screencastDir, "recording.webm")
	if err := os.WriteFile(source, []byte("video"), 0644); err != nil {
		t.Fatal(err)
	}
	tempPath := ""
	converter := func(_, destination string, _ bool) ([]byte, error) {
		tempPath = destination
		return nil, os.WriteFile(destination, testGIF, 0644)
	}

	err := processVideoWithConverter(
		source,
		config,
		time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC),
		0,
		converter,
	)
	if err == nil || !strings.Contains(err.Error(), "metadata") {
		t.Fatalf("expected metadata failure, got %v", err)
	}
	assertPathExists(t, source)
	assertDirectoryEmpty(t, hostedDir)
	assertPathMissing(t, tempPath)
	assertPathMissing(t, filepath.Join(config.StateDir, latestURLMarker))
}

func TestConcurrentVideoConversionsUseDistinctTemporaryAndHostedNames(t *testing.T) {
	config := newIngestionConfig(t)
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	var mutex sync.Mutex
	var tempPaths []string
	converter := func(_, destination string, _ bool) ([]byte, error) {
		mutex.Lock()
		tempPaths = append(tempPaths, destination)
		mutex.Unlock()
		return nil, os.WriteFile(destination, testGIF, 0644)
	}

	const workers = 2
	var wait sync.WaitGroup
	errorsCh := make(chan error, workers)
	for worker := 0; worker < workers; worker++ {
		source := filepath.Join(config.ScreencastDir, fmt.Sprintf("recording-%d.webm", worker))
		if err := os.WriteFile(source, []byte("video"), 0644); err != nil {
			t.Fatal(err)
		}
		wait.Add(1)
		go func(source string) {
			defer wait.Done()
			errorsCh <- processVideoWithConverter(source, config, now, 0, converter)
		}(source)
	}
	wait.Wait()
	close(errorsCh)
	for err := range errorsCh {
		if err != nil {
			t.Fatal(err)
		}
	}

	mutex.Lock()
	defer mutex.Unlock()
	if len(tempPaths) != workers || tempPaths[0] == tempPaths[1] {
		t.Fatalf("temporary paths were not unique: %v", tempPaths)
	}
	for _, path := range tempPaths {
		assertPathMissing(t, path)
	}
	hosted := regularFileNames(t, filepath.Join(config.DataDir, "hosted"))
	wantHosted := []string{"20260827-1200-1.gif", "20260827-1200.gif"}
	if strings.Join(hosted, ",") != strings.Join(wantHosted, ",") {
		t.Fatalf("hosted files = %v, want %v", hosted, wantHosted)
	}
}

func newIngestionConfig(t *testing.T) Config {
	t.Helper()
	root := t.TempDir()
	config := Config{
		ScreenshotDir: filepath.Join(root, "screenshots"),
		ScreencastDir: filepath.Join(root, "screencasts"),
		DataDir:       filepath.Join(root, "data"),
		StateDir:      filepath.Join(root, "state"),
		BaseURL:       "https://ss.test",
	}
	for _, directory := range []string{
		config.ScreenshotDir,
		config.ScreencastDir,
		filepath.Join(config.DataDir, "hosted"),
		filepath.Join(config.DataDir, "metadata"),
	} {
		if err := os.MkdirAll(directory, 0755); err != nil {
			t.Fatal(err)
		}
	}
	return config
}

func regularFileNames(t *testing.T, directory string) []string {
	t.Helper()
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, entry := range entries {
		if entry.Type().IsRegular() {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	return names
}
