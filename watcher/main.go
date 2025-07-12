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
	ID          string    `json:"id"`
	OriginalName string   `json:"original_name"`
	Filename    string    `json:"filename"`
	URL         string    `json:"url"`
	Timestamp   time.Time `json:"timestamp"`
	Description string    `json:"description,omitempty"`
	BatchID     string    `json:"batch_id,omitempty"`
	Preserve    bool      `json:"preserve"`
	RepoName    string    `json:"repo_name,omitempty"`
	Size        int64     `json:"size"`
}

type Config struct {
	WatchDir    string
	DataDir     string
	BaseURL     string
}

func main() {
	config := Config{
		WatchDir: getEnv("SSBNK_WATCH_DIR", "/watch"),
		DataDir:  getEnv("SSBNK_DATA_DIR", "/data"),
		BaseURL:  getEnv("SSBNK_URL", "https://localhost"),
	}

	log.Printf("Starting ssbnk watcher...")
	log.Printf("Watch directory: %s", config.WatchDir)
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
				if event.Op&fsnotify.Create == fsnotify.Create {
					if isImageFile(event.Name) {
						log.Printf("New screenshot detected: %s", event.Name)
						// Small delay to ensure file is fully written
						time.Sleep(100 * time.Millisecond)
						if err := processScreenshot(event.Name, config); err != nil {
							log.Printf("Error processing screenshot: %v", err)
						}
					}
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

	log.Printf("Watching for screenshots in %s", config.WatchDir)
	
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

	log.Printf("Screenshot processed: %s -> %s", filepath.Base(sourcePath), url)
	return nil
}

func isImageFile(filename string) bool {
	ext := strings.ToLower(filepath.Ext(filename))
	return ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".gif" || ext == ".webp"
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
