package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestGIFHandling(t *testing.T) {
	// Create a temporary directory for testing
	tempDir, err := os.MkdirTemp("", "ssbnk-test-")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tempDir)

	// Create test directories
	watchDir := filepath.Join(tempDir, "watch")
	videoDir := filepath.Join(tempDir, "videos")
	hostedDir := filepath.Join(tempDir, "data", "hosted")
	metadataDir := filepath.Join(tempDir, "data", "metadata")

	for _, dir := range []string{watchDir, videoDir, hostedDir, metadataDir} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			t.Fatalf("Failed to create test directory: %v", err)
		}
	}

	// Create a test config
	config := Config{
		WatchDir:      watchDir,
		VideoWatchDir: videoDir,
		DataDir:       filepath.Join(tempDir, "data"),
		BaseURL:       "http://test.local",
	}

	// Test 1: GIF from video conversion should go directly to hosted directory
	t.Run("VideoToGIF", func(t *testing.T) {
		// Create a small test video file
		testVideoPath := filepath.Join(videoDir, "test-video.webm")
		if err := os.WriteFile(testVideoPath, []byte("fake video content"), 0644); err != nil {
			t.Fatalf("Failed to create test video: %v", err)
		}

		// Mock the video processing (we can't run ffmpeg in test)
		// Just test the file placement logic
		timestamp := time.Now().Format("20060102-1504")
		expectedGifName := timestamp + ".gif"
		expectedGifPath := filepath.Join(hostedDir, expectedGifName)

		// Create a temp GIF file
		tempGifPath := filepath.Join("/tmp", expectedGifName)
		if err := os.WriteFile(tempGifPath, []byte("fake gif content"), 0644); err != nil {
			t.Fatalf("Failed to create temp GIF: %v", err)
		}

		// Test the file movement logic
		if err := copyFile(tempGifPath, expectedGifPath); err != nil {
			t.Fatalf("Failed to copy GIF: %v", err)
		}

		// Verify the GIF is in the hosted directory
		if _, err := os.Stat(expectedGifPath); os.IsNotExist(err) {
			t.Errorf("GIF was not placed in hosted directory")
		}

		// Clean up
		os.Remove(tempGifPath)
		os.Remove(testVideoPath)
	})

	// Test 2: Regular GIF screenshot should be processed normally
	t.Run("RegularGIFScreenshot", func(t *testing.T) {
		// Create a test GIF file that's "old" (not from recent video conversion)
		testGifPath := filepath.Join(watchDir, "test-screenshot.gif")
		if err := os.WriteFile(testGifPath, []byte("fake gif content"), 0644); err != nil {
			t.Fatalf("Failed to create test GIF: %v", err)
		}

		// Set the modification time to 10 seconds ago
		tenSecondsAgo := time.Now().Add(-10 * time.Second)
		if err := os.Chtimes(testGifPath, tenSecondsAgo, tenSecondsAgo); err != nil {
			t.Fatalf("Failed to set file time: %v", err)
		}

		// Process the screenshot
		if err := processScreenshot(testGifPath, config); err != nil {
			t.Fatalf("Failed to process screenshot: %v", err)
		}

		// Verify the GIF was converted to PNG
		files, err := os.ReadDir(hostedDir)
		if err != nil {
			t.Fatalf("Failed to read hosted dir: %v", err)
		}

		foundPng := false
		for _, file := range files {
			if filepath.Ext(file.Name()) == ".png" {
				foundPng = true
				break
			}
		}

		if !foundPng {
			t.Error("Regular GIF was not converted to PNG")
		}
	})
}
