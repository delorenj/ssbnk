package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
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
	ScreenshotDir      string
	ScreencastDir string
	DataDir       string
	BaseURL       string
}

func main() {
	config := Config{
		ScreenshotDir:      getEnv("SSBNK_SCREENSHOT_DIR", "/media/screenshots"),
		ScreencastDir: getEnv("SSBNK_SCREENCAST_DIR", "/media/screencasts"),
		DataDir:       getEnv("SSBNK_DATA_DIR", "/data"),
		BaseURL:       getEnv("SSBNK_URL", "https://ss.yourdomain.com"),
	}

	log.Printf("Starting ssbnk watcher...")
	log.Printf("Screenshot directory: %s", config.ScreenshotDir)
	log.Printf("Video watch directory: %s", config.ScreencastDir)
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

	err = watcher.Add(config.ScreenshotDir)
	if err != nil {
		log.Fatal("Failed to add watch directory:", err)
	}

	err = watcher.Add(config.ScreencastDir)
	if err != nil {
		log.Fatal("Failed to add video watch directory:", err)
	}

	log.Printf("Watching for screenshots in %s", config.ScreenshotDir)
	log.Printf("Watching for videos in %s", config.ScreencastDir)

	// Start HTTP server for API endpoints
	go startAPIServer(config)

	// Keep the program running
	select {}
}

func startAPIServer(config Config) {
	http.HandleFunc("/latest", func(w http.ResponseWriter, r *http.Request) {
		handleLatest(w, r, config)
	})
	http.HandleFunc("/latest/", func(w http.ResponseWriter, r *http.Request) {
		handleLatest(w, r, config)
	})

	port := "8081"
	log.Printf("Starting API server on port %s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatalf("Failed to start API server: %v", err)
	}
}

func handleLatest(w http.ResponseWriter, r *http.Request, config Config) {
	// Read all metadata files
	metadataDir := filepath.Join(config.DataDir, "metadata")
	files, err := os.ReadDir(metadataDir)
	if err != nil {
		http.Error(w, "Failed to read metadata directory", http.StatusInternalServerError)
		return
	}

	var allMetadata []ScreenshotMetadata
	for _, file := range files {
		if strings.HasSuffix(file.Name(), ".json") {
			filePath := filepath.Join(metadataDir, file.Name())
			data, err := os.ReadFile(filePath)
			if err != nil {
				log.Printf("Warning: Failed to read metadata file %s: %v", file.Name(), err)
				continue
			}

			var metadata ScreenshotMetadata
			if err := json.Unmarshal(data, &metadata); err != nil {
				log.Printf("Warning: Failed to unmarshal metadata file %s: %v", file.Name(), err)
				continue
			}
			allMetadata = append(allMetadata, metadata)
		}
	}

	// Sort by timestamp descending
	sort.Slice(allMetadata, func(i, j int) bool {
		return allMetadata[i].Timestamp.After(allMetadata[j].Timestamp)
	})

	// Get offset from URL path
	offset := 0
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) > 1 {
		if val, err := strconv.Atoi(parts[1]); err == nil {
			offset = val
		}
	}

	if offset >= len(allMetadata) {
		http.Error(w, "Not found: offset is out of range", http.StatusNotFound)
		return
	}

	// Get the target metadata
	targetMetadata := allMetadata[offset]

	// Redirect to the image URL
	http.Redirect(w, r, targetMetadata.URL, http.StatusFound)
}

func processScreenshot(sourcePath string, config Config) error {
	// Special handling for GIF files that might be from video conversion
	if strings.HasSuffix(strings.ToLower(sourcePath), ".gif") {
		// Check if this GIF was created recently (likely from video conversion)
		fileInfo, err := os.Stat(sourcePath)
		if err != nil {
			return fmt.Errorf("failed to get file info: %w", err)
		}

		// If created within last 5 seconds, it's likely from video conversion
		if time.Since(fileInfo.ModTime()) < 5*time.Second {
			// Move directly to hosted directory without renaming
			destPath := filepath.Join(config.DataDir, "hosted", filepath.Base(sourcePath))

			// Ensure unique filename (unlikely needed for GIFs but just in case)
			counter := 1
			originalDestPath := destPath
			for fileExists(destPath) {
				destPath = fmt.Sprintf("%s-%d.gif", strings.TrimSuffix(originalDestPath, ".gif"), counter)
				counter++
			}

			// Move the file
			if err := os.Rename(sourcePath, destPath); err != nil {
				// If rename fails (cross-device), fall back to copy
				if err := copyFile(sourcePath, destPath); err != nil {
					return fmt.Errorf("failed to move GIF: %w", err)
				}
				// Remove original after successful copy
				if err := os.Remove(sourcePath); err != nil {
					log.Printf("Warning: Failed to remove original GIF: %v", err)
				}
			}

			// Generate URL with original filename
			url := fmt.Sprintf("%s/hosted/%s", config.BaseURL, filepath.Base(destPath))

			// Create metadata
			metadata := ScreenshotMetadata{
				ID:           uuid.New().String(),
				OriginalName: filepath.Base(sourcePath),
				Filename:     filepath.Base(destPath),
				URL:          url,
				Timestamp:    time.Now(),
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

			// Play notification sound for GIF
			playNotificationSound()

			// Open GIF in browser
			log.Printf("Opening GIF in browser: %s", url)
			if err := openInBrowser(url); err != nil {
				log.Printf("Warning: Failed to open in browser: %v", err)
			}

			log.Printf("GIF processed: %s -> %s", filepath.Base(sourcePath), url)
			return nil
		}
	}

	// Regular screenshot processing for non-GIF or older GIF files
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

	log.Printf("Screenshot processed: %s -> %s", filepath.Base(sourcePath), url)
	return nil
}

func processVideo(sourcePath string, config Config) error {
	// Generate GIF filename with timestamp
	now := time.Now()
	gifFilename := fmt.Sprintf("%s.gif", now.Format("20060102-1504"))
	tempGifPath := filepath.Join("/tmp", gifFilename)
	hostedGifPath := filepath.Join(config.DataDir, "hosted", gifFilename)

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

	// Move GIF directly to hosted directory (skip watch directory)
	// First try rename (atomic operation)
	err := os.Rename(tempGifPath, hostedGifPath)
	if err != nil {
		// If rename fails (cross-device), fall back to copy
		if err := copyFile(tempGifPath, hostedGifPath); err != nil {
			return fmt.Errorf("failed to move GIF to hosted directory: %w", err)
		}
		// Remove temp file after successful copy
		if err := os.Remove(tempGifPath); err != nil {
			log.Printf("Warning: Failed to remove temp GIF: %v", err)
		}
	}

	// Get file info for metadata
	fileInfo, err := os.Stat(hostedGifPath)
	if err != nil {
		return fmt.Errorf("failed to get GIF file info: %w", err)
	}

	// Generate URL
	url := fmt.Sprintf("%s/hosted/%s", config.BaseURL, gifFilename)

	// Create metadata
	metadata := ScreenshotMetadata{
		ID:           uuid.New().String(),
		OriginalName: filepath.Base(sourcePath),
		Filename:     gifFilename,
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

	// Play notification sound
	playNotificationSound()

	// Open GIF in browser
	log.Printf("Opening GIF in browser: %s", url)
	if err := openInBrowser(url); err != nil {
		log.Printf("Warning: Failed to open in browser: %v", err)
	}

	// Remove the original video file
	if err := os.Remove(sourcePath); err != nil {
		log.Printf("Warning: Failed to remove original video: %v", err)
	}

	log.Printf("Video converted to GIF: %s -> %s", filepath.Base(sourcePath), url)
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

func copyFile(src, dst string) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("failed to open source file: %w", err)
	}
	defer sourceFile.Close()

	destFile, err := os.Create(dst)
	if err != nil {
		return fmt.Errorf("failed to create destination file: %w", err)
	}
	defer destFile.Close()

	if _, err := destFile.ReadFrom(sourceFile); err != nil {
		return fmt.Errorf("failed to copy file: %w", err)
	}
	return nil
}

func playNotificationSound() {
	// Generate a simple beep sound using ffplay (part of ffmpeg)
	// This creates a 0.2 second sine wave at 800Hz
	cmd := exec.Command("ffplay",
		"-nodisp",
		"-autoexit",
		"-f", "lavfi",
		"-i", "sine=frequency=800:duration=0.2",
	)

	// Run in background so it doesn't block
	go func() {
		if err := cmd.Run(); err != nil {
			// If ffplay fails, try alternative methods
			// Try using the system beep
			if beepCmd := exec.Command("printf", "\a"); beepCmd.Run() != nil {
				log.Printf("Warning: Failed to play notification sound: %v", err)
			}
		}
	}()
}
