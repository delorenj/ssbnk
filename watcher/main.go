package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"
	"github.com/google/uuid"
)

type ScreenshotMetadata struct {
	ID           string    `json:"id"`
	OriginalName string    `json:"original_name"`
	Filename     string    `json:"filename"`
	URL          string    `json:"url"`
	Timestamp    time.Time `json:"timestamp"`
	Description  string    `json:"description,omitempty"`
	BatchID      string    `json:"batch_id,omitempty"`
	Preserve     bool      `json:"preserve"`
	RepoName     string    `json:"repo_name,omitempty"`
	Size         int64     `json:"size"`
}

type Config struct {
	WatchDir      string
	VideoWatchDir string
	DataDir       string
	BaseURL       string
}

func main() {
	config := Config{
		WatchDir:      getEnv("SSBNK_IMAGE_DIR", "/watch"),
		VideoWatchDir: getEnv("SSBNK_VIDEO_DIR", "/videos"),
		DataDir:       getEnv("SSBNK_DATA_DIR", "/data"),
		BaseURL:       getEnv("SSBNK_URL", "https://screenshots.yourdomain.com"),
	}

	log.Printf("Starting ssbnk watcher...")
	log.Printf("Watch directory: %s", config.WatchDir)
	log.Printf("Video watch directory: %s", config.VideoWatchDir)
	log.Printf("Data directory: %s", config.DataDir)
	log.Printf("Base URL: %s", config.BaseURL)

	// Log display server information
	if isWayland() {
		log.Printf("Display server: Wayland (WAYLAND_DISPLAY=%s, XDG_SESSION_TYPE=%s)",
			os.Getenv("WAYLAND_DISPLAY"), os.Getenv("XDG_SESSION_TYPE"))
	} else {
		log.Printf("Display server: X11 (DISPLAY=%s)", os.Getenv("DISPLAY"))
	}

	// Ensure directories exist
	if err := os.MkdirAll(filepath.Join(config.DataDir, "hosted"), 0755); err != nil {
		log.Fatal("Failed to create hosted directory:", err)
	}
	if err := os.MkdirAll(filepath.Join(config.DataDir, "metadata"), 0755); err != nil {
		log.Fatal("Failed to create metadata directory:", err)
	}

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		log.Fatal("Failed to create watcher:", err)
	}
	defer watcher.Close()

	// Start watching
	go func() {
		for {
			select {
			case event, ok := <-watcher.Events:
				if !ok {
					return
				}
				// For screenshots, process on create (they're saved instantly)
				if event.Op&fsnotify.Create == fsnotify.Create && isImageFile(event.Name) {
					log.Printf("New screenshot detected: %s", event.Name)
					// Small delay to ensure file is fully written
					time.Sleep(100 * time.Millisecond)
					if err := processScreenshot(event.Name, config); err != nil {
						log.Printf("Error processing screenshot: %v", err)
					}
				}

				// For videos, we need to track them and wait for write completion
				if event.Op&fsnotify.Create == fsnotify.Create && isVideoFile(event.Name) {
					log.Printf("Video recording started: %s", event.Name)
					// Track this video file for completion
					go trackVideoFile(event.Name, config)
				}
			case err, ok := <-watcher.Errors:
				if !ok {
					return
				}
				log.Printf("Watcher error: %v", err)
			}
		}
	}()

	err = watcher.Add(config.WatchDir)
	if err != nil {
		log.Fatal("Failed to add watch directory:", err)
	}

	err = watcher.Add(config.VideoWatchDir)
	if err != nil {
		log.Fatal("Failed to add video watch directory:", err)
	}

	log.Printf("Watching for screenshots in %s", config.WatchDir)
	log.Printf("Watching for videos in %s", config.VideoWatchDir)

	// Keep the program running
	select {}
}

func processScreenshot(sourcePath string, config Config) error {
	// Generate new filename with timestamp
	now := time.Now()
	newFilename := fmt.Sprintf("%s.png", now.Format("20060102-1504"))

	// Ensure unique filename
	destPath := filepath.Join(config.DataDir, "hosted", newFilename)
	counter := 1
	for fileExists(destPath) {
		newFilename = fmt.Sprintf("%s-%d.png", now.Format("20060102-1504"), counter)
		destPath = filepath.Join(config.DataDir, "hosted", newFilename)
		counter++
	}

	// Get file info
	fileInfo, err := os.Stat(sourcePath)
	if err != nil {
		return fmt.Errorf("failed to get file info: %w", err)
	}

	// Copy file to hosted directory (can't use rename across volumes)
	sourceFile, err := os.Open(sourcePath)
	if err != nil {
		return fmt.Errorf("failed to open source file: %w", err)
	}
	defer sourceFile.Close()

	destFile, err := os.Create(destPath)
	if err != nil {
		return fmt.Errorf("failed to create destination file: %w", err)
	}
	defer destFile.Close()

	if _, err := destFile.ReadFrom(sourceFile); err != nil {
		return fmt.Errorf("failed to copy file: %w", err)
	}

	// Remove the original file
	if err := os.Remove(sourcePath); err != nil {
		log.Printf("Warning: Failed to remove original file: %v", err)
	}

	// Generate URL
	url := fmt.Sprintf("%s/hosted/%s", config.BaseURL, newFilename)

	// Create metadata
	metadata := ScreenshotMetadata{
		ID:           uuid.New().String(),
		OriginalName: filepath.Base(sourcePath),
		Filename:     newFilename,
		URL:          url,
		Timestamp:    now,
		Size:         fileInfo.Size(),
		Preserve:     false,
	}

	// Save metadata
	metadataPath := filepath.Join(config.DataDir, "metadata", fmt.Sprintf("%s.json", metadata.ID))
	if err := saveMetadata(metadata, metadataPath); err != nil {
		log.Printf("Warning: Failed to save metadata: %v", err)
	}

	// Copy URL to clipboard
	if err := copyToClipboard(url); err != nil {
		log.Printf("Warning: Failed to copy to clipboard: %v", err)
	}

	// If this is a GIF (from video conversion), open it in browser
	if strings.HasSuffix(strings.ToLower(newFilename), ".gif") {
		log.Printf("Opening GIF in browser: %s", url)
		if err := openInBrowser(url); err != nil {
			log.Printf("Warning: Failed to open in browser: %v", err)
		}
	}

	log.Printf("Screenshot processed: %s -> %s", filepath.Base(sourcePath), url)
	return nil
}

func processVideo(sourcePath string, config Config) error {
	// Generate temporary GIF filename
	now := time.Now()
	gifFilename := fmt.Sprintf("%s.gif", now.Format("20060102-1504"))
	tempGifPath := filepath.Join("/tmp", gifFilename)

	// Convert video to GIF using ffmpeg
	log.Printf("Converting video to GIF: %s", filepath.Base(sourcePath))

	// Try conversion with retries
	var lastErr error
	for attempt := 1; attempt <= 3; attempt++ {
		if attempt > 1 {
			log.Printf("Retrying video conversion (attempt %d/3)...", attempt)
			time.Sleep(2 * time.Second)
		}

		// FFmpeg command to create a high-quality looping GIF
		// -y: overwrite output files
		// -t 10: limit to first 10 seconds
		// -vf: video filters for scaling and generating palette for better colors
		// -loop 0: infinite loop
		cmd := exec.Command("ffmpeg",
			"-y", // Overwrite output files
			"-i", sourcePath,
			"-t", "10", // Limit to 10 seconds
			"-vf", "fps=10,scale=640:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
			"-loop", "0",
			tempGifPath,
		)

		output, err := cmd.CombinedOutput()
		if err == nil {
			// Success! Check if output file exists
			if _, err := os.Stat(tempGifPath); err == nil {
				log.Printf("Video conversion successful on attempt %d", attempt)
				break
			}
			lastErr = fmt.Errorf("output file not created")
		} else {
			lastErr = fmt.Errorf("ffmpeg error: %w\nOutput: %s", err, string(output))

			// If it's a file format issue, try with format detection
			if attempt == 2 {
				log.Printf("Trying with explicit format detection...")
				cmd = exec.Command("ffmpeg",
					"-y",
					"-f", "matroska", // Try explicit format
					"-i", sourcePath,
					"-t", "10",
					"-vf", "fps=10,scale=640:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
					"-loop", "0",
					tempGifPath,
				)

				output, err = cmd.CombinedOutput()
				if err == nil {
					if _, err := os.Stat(tempGifPath); err == nil {
						log.Printf("Video conversion successful with format detection")
						break
					}
				}
			}
		}
	}

	if lastErr != nil {
		return fmt.Errorf("video conversion failed after 3 attempts: %w", lastErr)
	}

	// Move GIF to watch directory for processing
	destPath := filepath.Join(config.WatchDir, gifFilename)

	// Copy the GIF file
	sourceFile, err := os.Open(tempGifPath)
	if err != nil {
		return fmt.Errorf("failed to open temp GIF: %w", err)
	}
	defer sourceFile.Close()

	destFile, err := os.Create(destPath)
	if err != nil {
		return fmt.Errorf("failed to create destination GIF: %w", err)
	}
	defer destFile.Close()

	if _, err := destFile.ReadFrom(sourceFile); err != nil {
		return fmt.Errorf("failed to copy GIF: %w", err)
	}

	// Clean up temp file
	os.Remove(tempGifPath)

	// Remove the original video file
	if err := os.Remove(sourcePath); err != nil {
		log.Printf("Warning: Failed to remove original video: %v", err)
	}

	log.Printf("Video converted to GIF: %s -> %s", filepath.Base(sourcePath), gifFilename)
	return nil
}

func isImageFile(filename string) bool {
	ext := strings.ToLower(filepath.Ext(filename))
	return ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".gif" || ext == ".webp"
}

func isVideoFile(filename string) bool {
	ext := strings.ToLower(filepath.Ext(filename))
	return ext == ".mp4" || ext == ".avi" || ext == ".mov" || ext == ".mkv" || ext == ".webm" || ext == ".flv" || ext == ".wmv"
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return !os.IsNotExist(err)
}

func saveMetadata(metadata ScreenshotMetadata, path string) error {
	data, err := json.MarshalIndent(metadata, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

func copyToClipboard(text string) error {
	// First try: Direct clipboard access
	var err error
	if isWayland() {
		cmd := exec.Command("wl-copy")
		cmd.Stdin = strings.NewReader(text)
		err = cmd.Run()
	} else {
		cmd := exec.Command("xclip", "-selection", "clipboard")
		cmd.Stdin = strings.NewReader(text)
		err = cmd.Run()
	}

	if err == nil {
		log.Printf("✅ Clipboard: Direct access successful")
		return nil
	}

	log.Printf("⚠️  Direct clipboard failed: %v", err)

	// Fallback 1: Use host clipboard bridge (FIFO)
	if err := useClipboardBridge(text); err == nil {
		log.Printf("✅ Clipboard: Bridge access successful")
		return nil
	}

	// Fallback 2: Use HTTP clipboard service
	if err := useHTTPClipboard(text); err == nil {
		log.Printf("✅ Clipboard: HTTP service successful")
		return nil
	}

	log.Printf("❌ All clipboard methods failed")
	return fmt.Errorf("all clipboard methods failed")
}

func useClipboardBridge(text string) error {
	// Try to write to the named pipe
	fifoPath := "/tmp/ssbnk-clipboard"

	// Check if FIFO exists
	if _, err := os.Stat(fifoPath); os.IsNotExist(err) {
		return fmt.Errorf("clipboard bridge not available")
	}

	// Open the FIFO for writing with timeout
	file, err := os.OpenFile(fifoPath, os.O_WRONLY, 0)
	if err != nil {
		return fmt.Errorf("failed to open clipboard bridge: %w", err)
	}
	defer file.Close()

	_, err = file.WriteString(text + "\n")
	return err
}

func useHTTPClipboard(text string) error {
	// Try HTTP clipboard service on host
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Post("http://localhost:9999", "text/plain", strings.NewReader(text))
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return fmt.Errorf("HTTP clipboard service returned %d", resp.StatusCode)
	}

	return nil
}

func isWayland() bool {
	// Primary check: Wayland display environment variable
	if os.Getenv("WAYLAND_DISPLAY") != "" {
		log.Printf("Detected Wayland via WAYLAND_DISPLAY=%s", os.Getenv("WAYLAND_DISPLAY"))
		return true
	}

	// Secondary check: XDG session type
	if os.Getenv("XDG_SESSION_TYPE") == "wayland" {
		log.Printf("Detected Wayland via XDG_SESSION_TYPE=wayland")
		return true
	}

	// Fallback: Check if wl-copy is available and can connect to compositor
	if _, err := exec.LookPath("wl-copy"); err == nil {
		// Test if we can actually use wl-copy (compositor running)
		cmd := exec.Command("wl-copy", "--version")
		cmd.Env = os.Environ()
		if err := cmd.Run(); err == nil {
			log.Printf("Detected Wayland via wl-copy availability")
			return true
		}
	}

	log.Printf("Using X11 clipboard (xclip)")
	return false
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func trackVideoFile(filePath string, config Config) {
	log.Printf("Tracking video file for completion: %s", filepath.Base(filePath))

	// Initial delay to let recording start properly
	time.Sleep(2 * time.Second)

	var lastSize int64 = -1
	var lastModTime time.Time
	stableCount := 0
	requiredStableChecks := 6 // 3 seconds of no changes
	checkInterval := 500 * time.Millisecond
	maxWaitTime := 10 * time.Minute // Max recording time
	startTime := time.Now()

	for {
		// Check timeout
		if time.Since(startTime) > maxWaitTime {
			log.Printf("Video tracking timeout for: %s", filepath.Base(filePath))
			return
		}

		// Get file info
		fileInfo, err := os.Stat(filePath)
		if err != nil {
			if os.IsNotExist(err) {
				log.Printf("Video file was deleted: %s", filepath.Base(filePath))
				return
			}
			log.Printf("Error checking video file: %v", err)
			time.Sleep(checkInterval)
			continue
		}

		currentSize := fileInfo.Size()
		currentModTime := fileInfo.ModTime()

		// Check if file size and modification time are stable
		if currentSize == lastSize && currentSize > 0 && currentModTime.Equal(lastModTime) {
			stableCount++
			if stableCount >= requiredStableChecks {
				// Try to open the file exclusively
				file, err := os.OpenFile(filePath, os.O_RDWR|os.O_EXCL, 0)
				if err != nil {
					// File might still be locked by the recording software
					if stableCount < requiredStableChecks*2 {
						// Give it more time
						stableCount++
					} else {
						// Assume it's done after extended stable period
						log.Printf("Video recording complete (extended stable): %s (size: %s)",
							filepath.Base(filePath), formatBytes(currentSize))
						if err := processVideo(filePath, config); err != nil {
							log.Printf("Error processing video: %v", err)
						}
						return
					}
				} else {
					file.Close()
					log.Printf("Video recording complete: %s (size: %s)",
						filepath.Base(filePath), formatBytes(currentSize))
					if err := processVideo(filePath, config); err != nil {
						log.Printf("Error processing video: %v", err)
					}
					return
				}
			}
		} else {
			// Size or mod time changed, reset counter
			if currentSize != lastSize {
				log.Printf("Video still recording: %s (size: %s)",
					filepath.Base(filePath), formatBytes(currentSize))
			}
			stableCount = 0
			lastSize = currentSize
			lastModTime = currentModTime
		}

		time.Sleep(checkInterval)
	}
}

func formatBytes(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

func openInBrowser(url string) error {
	// Since we're in a container, we need to ensure proper display access
	// The container already has access to X11/Wayland through the volume mounts

	// Set up environment for xdg-open
	cmd := exec.Command("xdg-open", url)
	cmd.Env = os.Environ()

	// Ensure DISPLAY is set for X11
	if os.Getenv("DISPLAY") == "" {
		cmd.Env = append(cmd.Env, "DISPLAY=:0")
	}

	// For Wayland, ensure XDG_RUNTIME_DIR is set
	if isWayland() && os.Getenv("XDG_RUNTIME_DIR") == "" {
		cmd.Env = append(cmd.Env, "XDG_RUNTIME_DIR=/run/user/1000")
	}

	// Try to run xdg-open
	if err := cmd.Start(); err != nil {
		log.Printf("xdg-open failed: %v", err)

		// As a fallback, try writing to a named pipe that the host could monitor
		// This is similar to the clipboard bridge approach
		if err := notifyHostToOpen(url); err != nil {
			return fmt.Errorf("failed to open browser: %w", err)
		}
	}

	return nil
}

func notifyHostToOpen(url string) error {
	// Try to write to a host notification pipe (if it exists)
	notifyPath := "/tmp/ssbnk-browser"

	// Check if notification pipe exists
	if _, err := os.Stat(notifyPath); os.IsNotExist(err) {
		return fmt.Errorf("browser notification bridge not available")
	}

	// Open the FIFO for writing
	file, err := os.OpenFile(notifyPath, os.O_WRONLY, 0)
	if err != nil {
		return fmt.Errorf("failed to open browser bridge: %w", err)
	}
	defer file.Close()

	_, err = file.WriteString(url + "\n")
	return err
}
