package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
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
	ScreenshotDir string
	ScreencastDir string
	DataDir       string
	StateDir      string
	BaseURL       string
}

const (
	maxUploadFileBytes    = int64(50 << 20)
	maxUploadBodyBytes    = maxUploadFileBytes + int64(1<<20)
	maxGIFDurationSeconds = 30
	contentSniffBytes     = 512
)

func serve(config Config) error {
	log.Printf("Starting ssbnk watcher...")
	log.Printf("Screenshot directory: %s", config.ScreenshotDir)
	log.Printf("Video watch directory: %s", config.ScreencastDir)
	log.Printf("Data directory: %s", config.DataDir)
	log.Printf("State directory: %s", stateDirForConfig(config))
	log.Printf("Base URL: %s", config.BaseURL)

	// Ensure directories exist
	if err := os.MkdirAll(filepath.Join(config.DataDir, "hosted"), 0755); err != nil {
		return fmt.Errorf("create hosted directory: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(config.DataDir, "metadata"), 0755); err != nil {
		return fmt.Errorf("create metadata directory: %w", err)
	}

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return fmt.Errorf("create watcher: %w", err)
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
				// For screenshots, process on create/rename in a goroutine so the watcher loop never blocks.
				if (event.Op&fsnotify.Create == fsnotify.Create || event.Op&fsnotify.Rename == fsnotify.Rename) && isImageFile(event.Name) {
					log.Printf("New screenshot detected: %s", event.Name)
					go func(path string) {
						// Small delay to ensure file is fully written
						time.Sleep(100 * time.Millisecond)
						if err := processScreenshot(path, config); err != nil {
							log.Printf("Error processing screenshot: %v", err)
						}
					}(event.Name)
				}

				// For videos, we need to track them and wait for write completion
				if (event.Op&fsnotify.Create == fsnotify.Create || event.Op&fsnotify.Rename == fsnotify.Rename) && isVideoFile(event.Name) {
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
		return fmt.Errorf("watch screenshot directory: %w", err)
	}

	err = watcher.Add(config.ScreencastDir)
	if err != nil {
		return fmt.Errorf("watch screencast directory: %w", err)
	}

	log.Printf("Watching for screenshots in %s", config.ScreenshotDir)
	log.Printf("Watching for videos in %s", config.ScreencastDir)

	// Start HTTP server for API endpoints
	serverErrors := make(chan error, 1)
	go func() {
		serverErrors <- startAPIServer(config)
	}()

	// Start memory logger
	go logMemoryUsage()

	return <-serverErrors
}

func startAPIServer(config Config) error {
	mux := http.NewServeMux()

	// API endpoints
	mux.HandleFunc("/api/screenshots", func(w http.ResponseWriter, r *http.Request) {
		handleAPIScreenshots(w, r, config)
	})
	mux.HandleFunc("/latest", func(w http.ResponseWriter, r *http.Request) {
		handleLatest(w, r, config)
	})
	mux.HandleFunc("/latest/", func(w http.ResponseWriter, r *http.Request) {
		handleLatest(w, r, config)
	})
	mux.HandleFunc("/hybrid", func(w http.ResponseWriter, r *http.Request) {
		handleLatestHybrid(w, r, config)
	})
	mux.HandleFunc("/hybrid/", func(w http.ResponseWriter, r *http.Request) {
		handleLatestHybrid(w, r, config)
	})
	mux.HandleFunc("/stateless", func(w http.ResponseWriter, r *http.Request) {
		handleLatestStateless(w, r, config)
	})
	mux.HandleFunc("/stateless/", func(w http.ResponseWriter, r *http.Request) {
		handleLatestStateless(w, r, config)
	})
	mux.HandleFunc("/upload", func(w http.ResponseWriter, r *http.Request) {
		handleUpload(w, r, config)
	})
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		handleHealthCheck(w, r, config)
	})

	// Static file servers
	hostedDir := filepath.Join(config.DataDir, "hosted")
	hostedFS := http.FileServer(http.Dir(hostedDir))
	uiDir := getEnv("SSBNK_UI_DIR", "/ui")
	uiFS := http.FileServer(http.Dir(uiDir))

	// Root handler: route between UI and hosted screenshot files
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path

		// Astro static assets
		if strings.HasPrefix(path, "/_astro/") || path == "/favicon.svg" {
			uiFS.ServeHTTP(w, r)
			return
		}

		// Image/gif files: serve from hosted directory
		if isImageFile(path) {
			hostedFS.ServeHTTP(w, r)
			return
		}

		// Everything else: serve UI index.html (Astro static page)
		http.ServeFile(w, r, filepath.Join(uiDir, "index.html"))
	})

	// Wrap with security headers and CORS
	handler := withHeaders(mux)

	port := getEnv("SSBNK_API_PORT", "80")
	log.Printf("Starting server on port %s (static files + API)", port)
	if err := http.ListenAndServe(":"+port, handler); err != nil {
		return fmt.Errorf("serve HTTP: %w", err)
	}
	return nil
}

// withHeaders adds security headers and CORS to all responses
func withHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "SAMEORIGIN")
		w.Header().Set("Referrer-Policy", "strict-origin-when-cross-origin")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Upload-Key, X-API-Key")

		w.Header().Set("Cache-Control", cacheControlForPath(r.URL.Path))

		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func cacheControlForPath(path string) string {
	switch {
	case strings.HasPrefix(path, "/_astro/"):
		// Astro fingerprints build assets, so different releases never share a URL.
		return "public, max-age=31536000, immutable"
	case isImageFile(path):
		return "public, max-age=86400, immutable"
	case strings.HasPrefix(path, "/api/"),
		path == "/health",
		path == "/upload",
		path == "/latest" || strings.HasPrefix(path, "/latest/"),
		path == "/hybrid" || strings.HasPrefix(path, "/hybrid/"),
		path == "/stateless" || strings.HasPrefix(path, "/stateless/"):
		return "no-store"
	default:
		// The HTML references fingerprinted assets from the current image. Force
		// clients to revalidate it so cached markup cannot point at retired chunks.
		return "no-cache"
	}
}

// handleAPIScreenshots returns screenshot metadata as JSON for the UI
func handleAPIScreenshots(w http.ResponseWriter, r *http.Request, config Config) {
	limit := 50
	offset := 0

	if val := r.URL.Query().Get("limit"); val != "" {
		if v, err := strconv.Atoi(val); err == nil && v > 0 {
			limit = v
		}
	}
	if val := r.URL.Query().Get("offset"); val != "" {
		if v, err := strconv.Atoi(val); err == nil && v >= 0 {
			offset = v
		}
	}

	// Load metadata and sort by timestamp desc
	allMetadata := loadAllMetadata(config)
	sort.Slice(allMetadata, func(i, j int) bool {
		return allMetadata[i].Timestamp.After(allMetadata[j].Timestamp)
	})

	// Fill gaps: include hosted files missing metadata
	metadataFilenames := make(map[string]bool)
	for _, m := range allMetadata {
		metadataFilenames[m.Filename] = true
	}
	for _, filename := range scanHostedFilesForLatest(config) {
		if !metadataFilenames[filename] {
			hostedPath := filepath.Join(config.DataDir, "hosted", filename)
			info, err := os.Stat(hostedPath)
			if err != nil {
				continue
			}
			allMetadata = append(allMetadata, ScreenshotMetadata{
				Filename:  filename,
				URL:       fmt.Sprintf("%s/%s", config.BaseURL, filename),
				Timestamp: info.ModTime(),
				Size:      info.Size(),
			})
		}
	}

	// Re-sort after adding gap fills
	sort.Slice(allMetadata, func(i, j int) bool {
		return allMetadata[i].Timestamp.After(allMetadata[j].Timestamp)
	})

	// Apply pagination
	total := len(allMetadata)
	if offset >= total {
		allMetadata = []ScreenshotMetadata{}
	} else {
		end := offset + limit
		if end > total {
			end = total
		}
		allMetadata = allMetadata[offset:end]
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"screenshots": allMetadata,
		"total":       total,
		"offset":      offset,
		"limit":       limit,
	})
}

func logMemoryUsage() {
	for {
		var m runtime.MemStats
		runtime.ReadMemStats(&m)
		log.Printf("MEM: Alloc = %v MiB, TotalAlloc = %v MiB, Sys = %v MiB, NumGC = %v",
			m.Alloc/1024/1024, m.TotalAlloc/1024/1024, m.Sys/1024/1024, m.NumGC)
		time.Sleep(30 * time.Second)
	}
}

func handleLatest(w http.ResponseWriter, r *http.Request, config Config) {
	log.Printf("Handling /latest request: %s", r.URL.Path)

	// Read all metadata files
	metadataDir := filepath.Join(config.DataDir, "metadata")
	log.Printf("Reading metadata directory: %s", metadataDir)
	files, err := os.ReadDir(metadataDir)
	if err != nil {
		log.Printf("Error reading metadata directory: %v", err)
		http.Error(w, "Failed to read metadata directory", http.StatusInternalServerError)
		return
	}

	var allMetadata []ScreenshotMetadata
	log.Printf("Found %d files in metadata directory", len(files))
	for _, file := range files {
		if strings.HasSuffix(file.Name(), ".json") {
			log.Printf("Processing metadata file: %s", file.Name())
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
			log.Printf("Successfully parsed metadata for: %s (timestamp: %s)", metadata.Filename, metadata.Timestamp)
			allMetadata = append(allMetadata, metadata)
		}
	}
	log.Printf("Total metadata entries loaded: %d", len(allMetadata))

	// Sort by timestamp descending
	sort.Slice(allMetadata, func(i, j int) bool {
		return allMetadata[i].Timestamp.After(allMetadata[j].Timestamp)
	})

	// Get offset from URL path
	offset := 0
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	log.Printf("URL path: %s, parts: %v", r.URL.Path, parts)
	if len(parts) > 1 {
		if val, err := strconv.Atoi(parts[1]); err == nil {
			offset = val
			log.Printf("Parsed offset: %d", offset)
		}
	} else {
		log.Printf("No offset specified, using default: %d", offset)
	}

	log.Printf("Checking offset %d against %d total metadata entries", offset, len(allMetadata))
	if offset >= len(allMetadata) {
		log.Printf("Offset %d is out of range (have %d entries)", offset, len(allMetadata))
		http.Error(w, "Not found: offset is out of range", http.StatusNotFound)
		return
	}

	// Get the target metadata
	targetMetadata := allMetadata[offset]
	log.Printf("Redirecting to: %s", targetMetadata.URL)

	// Redirect to the image URL
	http.Redirect(w, r, targetMetadata.URL, http.StatusFound)
}

// NEW: Hybrid approach - tries metadata first, falls back to filesystem scan
func handleLatestHybrid(w http.ResponseWriter, r *http.Request, config Config) {
	log.Printf("🔄 Handling HYBRID /latest request: %s", r.URL.Path)

	// Extract offset from URL
	offset := parseOffsetFromURL(r.URL.Path)
	log.Printf("📊 Requested offset: %d", offset)

	// STRATEGY 1: Try metadata first (fast path)
	log.Printf("🔍 HYBRID Step 1: Attempting metadata lookup...")
	if metadata, success := tryMetadataLookup(config, offset); success {
		log.Printf("✅ HYBRID Success: Found via metadata - %s", metadata.URL)

		// Validate that the file actually exists (consistency check)
		hostedPath := filepath.Join(config.DataDir, "hosted", metadata.Filename)
		if fileExists(hostedPath) {
			log.Printf("✅ HYBRID Validation: File exists on disk")
			http.Redirect(w, r, metadata.URL, http.StatusFound)
			return
		} else {
			log.Printf("⚠️  HYBRID Warning: Metadata found but file missing on disk: %s", hostedPath)
			// Fall through to filesystem scan
		}
	}

	// STRATEGY 2: Filesystem scan fallback (bulletproof path)
	log.Printf("🔍 HYBRID Step 2: Falling back to filesystem scan...")
	if url, success := tryFilesystemLookup(config, offset); success {
		log.Printf("✅ HYBRID Success: Found via filesystem scan - %s", url)
		http.Redirect(w, r, url, http.StatusFound)
		return
	}

	// STRATEGY 3: Last resort - count actual files and give helpful error
	actualCount := countActualFiles(config)
	log.Printf("❌ HYBRID Failure: Offset %d not found. Actual file count: %d", offset, actualCount)

	errorMsg := fmt.Sprintf("File not found at offset %d. Available files: %d", offset, actualCount)
	http.Error(w, errorMsg, http.StatusNotFound)
}

// NEW: Pure filesystem approach - completely stateless and bulletproof
func handleLatestStateless(w http.ResponseWriter, r *http.Request, config Config) {
	log.Printf("🔄 Handling STATELESS /latest request: %s", r.URL.Path)

	offset := parseOffsetFromURL(r.URL.Path)
	log.Printf("📊 Requested offset: %d", offset)

	// Direct filesystem scan - no metadata dependency
	if url, success := tryFilesystemLookup(config, offset); success {
		log.Printf("✅ STATELESS Success: Found via filesystem - %s", url)
		http.Redirect(w, r, url, http.StatusFound)
		return
	}

	actualCount := countActualFiles(config)
	log.Printf("❌ STATELESS Failure: Offset %d not found. Actual file count: %d", offset, actualCount)

	errorMsg := fmt.Sprintf("File not found at offset %d. Available files: %d", offset, actualCount)
	http.Error(w, errorMsg, http.StatusNotFound)
}

// NEW: Health check with metadata consistency validation
func handleHealthCheck(w http.ResponseWriter, r *http.Request, config Config) {
	log.Printf("🔄 Handling HEALTH CHECK request")

	type HealthStatus struct {
		Status            string   `json:"status"`
		MetadataCount     int      `json:"metadata_count"`
		ActualFileCount   int      `json:"actual_file_count"`
		ConsistencyIssues []string `json:"consistency_issues,omitempty"`
		Timestamp         string   `json:"timestamp"`
	}

	health := HealthStatus{
		Status:    "ok",
		Timestamp: time.Now().Format(time.RFC3339),
	}

	// Check metadata consistency
	issues := checkMetadataConsistency(config)
	health.ConsistencyIssues = issues
	health.MetadataCount = len(loadAllMetadata(config))
	health.ActualFileCount = countActualFiles(config)

	if len(issues) > 0 {
		health.Status = "warning"
		log.Printf("⚠️  HEALTH: Found %d consistency issues", len(issues))
	} else {
		log.Printf("✅ HEALTH: All systems operational")
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(health)
}

func handleUpload(w http.ResponseWriter, r *http.Request, config Config) {
	handleUploadWithLimits(w, r, config, maxUploadFileBytes, maxUploadBodyBytes)
}

func handleUploadWithLimits(w http.ResponseWriter, r *http.Request, config Config, maxFileBytes, maxBodyBytes int64) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Validate API key
	expectedKey := os.Getenv("SSBNK_UPLOAD_KEY")
	if expectedKey == "" {
		log.Printf("UPLOAD: SSBNK_UPLOAD_KEY not set, rejecting upload")
		http.Error(w, "Upload not configured", http.StatusServiceUnavailable)
		return
	}

	apiKey := r.Header.Get("X-Upload-Key")
	presentedKeyHash := sha256.Sum256([]byte(apiKey))
	expectedKeyHash := sha256.Sum256([]byte(expectedKey))
	if subtle.ConstantTimeCompare(presentedKeyHash[:], expectedKeyHash[:]) != 1 {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	// Bound the entire request as well as the uploaded file. The extra MiB is
	// reserved for multipart headers and boundaries, not file content.
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if err := r.ParseMultipartForm(maxFileBytes); err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			http.Error(w, "Upload too large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "Failed to parse upload", http.StatusBadRequest)
		return
	}
	if r.MultipartForm != nil {
		defer r.MultipartForm.RemoveAll()
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, "No file provided", http.StatusBadRequest)
		return
	}
	defer file.Close()

	// Sniff the bytes instead of trusting the client-supplied filename or MIME.
	sniff := make([]byte, contentSniffBytes)
	n, readErr := io.ReadFull(file, sniff)
	if readErr != nil && !errors.Is(readErr, io.EOF) && !errors.Is(readErr, io.ErrUnexpectedEOF) {
		http.Error(w, "Failed to read upload", http.StatusBadRequest)
		return
	}
	sniff = sniff[:n]
	detectedMIME := http.DetectContentType(sniff)
	ext, allowed := extensionForImageMIME(detectedMIME, filepath.Ext(header.Filename))
	if !allowed {
		http.Error(w, "Only PNG, JPEG, GIF, and WebP images are allowed", http.StatusUnsupportedMediaType)
		return
	}

	// Generate filename with timestamp
	now := time.Now()
	newFilename := fmt.Sprintf("%s%s", now.Format("20060102-1504"), ext)
	destPath := filepath.Join(config.DataDir, "hosted", newFilename)

	// Ensure unique filename
	counter := 1
	for fileExists(destPath) {
		newFilename = fmt.Sprintf("%s-%d%s", now.Format("20060102-1504"), counter, ext)
		destPath = filepath.Join(config.DataDir, "hosted", newFilename)
		counter++
	}

	// Write the uploaded file
	destFile, err := os.OpenFile(destPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0644)
	if err != nil {
		log.Printf("UPLOAD: Failed to create file: %v", err)
		http.Error(w, "Failed to save file", http.StatusInternalServerError)
		return
	}
	committed := false
	defer func() {
		_ = destFile.Close()
		if !committed {
			_ = os.Remove(destPath)
		}
	}()

	reader := io.MultiReader(bytes.NewReader(sniff), file)
	written, err := io.Copy(destFile, io.LimitReader(reader, maxFileBytes+1))
	if err != nil {
		log.Printf("UPLOAD: Failed to write file: %v", err)
		http.Error(w, "Failed to write file", http.StatusInternalServerError)
		return
	}
	if written > maxFileBytes {
		http.Error(w, "Upload too large", http.StatusRequestEntityTooLarge)
		return
	}
	if err := destFile.Sync(); err != nil {
		log.Printf("UPLOAD: Failed to sync file: %v", err)
		http.Error(w, "Failed to save file", http.StatusInternalServerError)
		return
	}
	if err := destFile.Close(); err != nil {
		log.Printf("UPLOAD: Failed to close file: %v", err)
		http.Error(w, "Failed to save file", http.StatusInternalServerError)
		return
	}

	// Generate URL
	url := fmt.Sprintf("%s/%s", config.BaseURL, newFilename)

	// Create metadata
	metadata := ScreenshotMetadata{
		ID:           uuid.New().String(),
		OriginalName: header.Filename,
		Filename:     newFilename,
		URL:          url,
		Timestamp:    now,
		Size:         written,
		Preserve:     false,
	}

	metadataPath := filepath.Join(config.DataDir, "metadata", fmt.Sprintf("%s.json", metadata.ID))
	if err := saveMetadata(metadata, metadataPath); err != nil {
		log.Printf("UPLOAD: Failed to save metadata: %v", err)
		http.Error(w, "Failed to save metadata", http.StatusInternalServerError)
		return
	}
	committed = true

	// Publish host-integration state. This is deliberately best-effort: a
	// missing clipboard bridge must never make an otherwise valid upload fail.
	publishIngestionState(config, destPath, url)

	log.Printf("UPLOAD: %s -> %s (%s)", header.Filename, url, formatBytes(written))

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"url":      url,
		"filename": newFilename,
	})
}

func extensionForImageMIME(detectedMIME, originalExtension string) (string, bool) {
	originalExtension = strings.ToLower(originalExtension)
	switch detectedMIME {
	case "image/png":
		return ".png", true
	case "image/jpeg":
		if originalExtension == ".jpeg" {
			return ".jpeg", true
		}
		return ".jpg", true
	case "image/gif":
		return ".gif", true
	case "image/webp":
		return ".webp", true
	default:
		return "", false
	}
}

func processScreenshot(sourcePath string, config Config) error {
	sourceFile, err := os.Open(sourcePath)
	if err != nil {
		return fmt.Errorf("failed to open source file: %w", err)
	}
	defer sourceFile.Close()

	extension, err := sniffImageExtension(sourceFile, filepath.Ext(sourcePath))
	if err != nil {
		return fmt.Errorf("inspect screenshot content: %w", err)
	}
	destPath, url, err := storeHostedAsset(
		sourceFile,
		filepath.Base(sourcePath),
		extension,
		time.Now(),
		config,
	)
	if err != nil {
		return err
	}

	if err := os.Remove(sourcePath); err != nil {
		log.Printf("Warning: Screenshot committed but source could not be removed: %v", err)
	}
	publishIngestionState(config, destPath, url)
	log.Printf("Screenshot processed: %s -> %s", filepath.Base(sourcePath), url)
	return nil
}

func processVideo(sourcePath string, config Config) error {
	return processVideoWithConverter(sourcePath, config, time.Now(), 2*time.Second, runFFmpegConversion)
}

type videoConverter func(sourcePath, destinationPath string, explicitMatroska bool) ([]byte, error)

func processVideoWithConverter(
	sourcePath string,
	config Config,
	now time.Time,
	retryDelay time.Duration,
	convert videoConverter,
) error {
	if convert == nil {
		return errors.New("video converter is not configured")
	}

	tempGIF, err := os.CreateTemp("", "ssbnk-video-*.gif")
	if err != nil {
		return fmt.Errorf("reserve temporary GIF: %w", err)
	}
	tempGIFPath := tempGIF.Name()
	if err := tempGIF.Close(); err != nil {
		_ = os.Remove(tempGIFPath)
		return fmt.Errorf("close temporary GIF: %w", err)
	}
	defer os.Remove(tempGIFPath)

	log.Printf("Converting video to GIF: %s", filepath.Base(sourcePath))
	var lastErr error
	converted := false
	for attempt := 1; attempt <= 3; attempt++ {
		if attempt > 1 {
			log.Printf("Retrying video conversion (attempt %d/3)...", attempt)
			if retryDelay > 0 {
				time.Sleep(retryDelay)
			}
		}

		if err := os.Truncate(tempGIFPath, 0); err != nil {
			return fmt.Errorf("reset temporary GIF: %w", err)
		}
		output, conversionErr := convert(sourcePath, tempGIFPath, false)
		if conversionErr == nil {
			if validationErr := validateGIF(tempGIFPath); validationErr == nil {
				lastErr = nil
				converted = true
				log.Printf("Video conversion successful on attempt %d", attempt)
				break
			} else {
				lastErr = validationErr
			}
		} else {
			lastErr = fmt.Errorf("ffmpeg error: %w; output: %s", conversionErr, strings.TrimSpace(string(output)))
		}

		if attempt == 2 {
			log.Printf("Trying video conversion with explicit Matroska format...")
			if err := os.Truncate(tempGIFPath, 0); err != nil {
				return fmt.Errorf("reset temporary GIF: %w", err)
			}
			output, conversionErr = convert(sourcePath, tempGIFPath, true)
			if conversionErr == nil {
				if validationErr := validateGIF(tempGIFPath); validationErr == nil {
					lastErr = nil
					converted = true
					log.Printf("Video conversion successful with explicit Matroska format")
					break
				} else {
					lastErr = validationErr
				}
			} else {
				lastErr = fmt.Errorf("ffmpeg explicit-format error: %w; output: %s", conversionErr, strings.TrimSpace(string(output)))
			}
		}
	}
	if !converted {
		if lastErr == nil {
			lastErr = errors.New("converter did not produce a GIF")
		}
		return fmt.Errorf("video conversion failed after 3 attempts: %w", lastErr)
	}

	convertedGIF, err := os.Open(tempGIFPath)
	if err != nil {
		return fmt.Errorf("open converted GIF: %w", err)
	}
	defer convertedGIF.Close()
	hostedPath, url, err := storeHostedAsset(
		convertedGIF,
		filepath.Base(sourcePath),
		".gif",
		now,
		config,
	)
	if err != nil {
		return err
	}

	if err := os.Remove(sourcePath); err != nil {
		log.Printf("Warning: Video committed but source could not be removed: %v", err)
	}
	publishIngestionState(config, hostedPath, url)
	log.Printf("Video converted to GIF: %s -> %s", filepath.Base(sourcePath), url)
	return nil
}

func runFFmpegConversion(sourcePath, destinationPath string, explicitMatroska bool) ([]byte, error) {
	return exec.Command("ffmpeg", ffmpegConversionArgs(sourcePath, destinationPath, explicitMatroska)...).CombinedOutput()
}

func ffmpegConversionArgs(sourcePath, destinationPath string, explicitMatroska bool) []string {
	args := []string{"-y"}
	if explicitMatroska {
		args = append(args, "-f", "matroska")
	}
	args = append(args,
		"-i", sourcePath,
		"-t", strconv.Itoa(maxGIFDurationSeconds),
		"-vf", "fps=10,scale=640:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
		"-loop", "0",
		destinationPath,
	)
	return args
}

func validateGIF(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open converted GIF: %w", err)
	}
	defer file.Close()
	buffer := make([]byte, contentSniffBytes)
	n, err := io.ReadFull(file, buffer)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return fmt.Errorf("read converted GIF: %w", err)
	}
	if http.DetectContentType(buffer[:n]) != "image/gif" {
		return errors.New("converter output is not a GIF")
	}
	return nil
}

func sniffImageExtension(file *os.File, originalExtension string) (string, error) {
	buffer := make([]byte, contentSniffBytes)
	n, err := io.ReadFull(file, buffer)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return "", err
	}
	extension, allowed := extensionForImageMIME(http.DetectContentType(buffer[:n]), originalExtension)
	if !allowed {
		return "", errors.New("file is not a supported image")
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return "", fmt.Errorf("rewind image: %w", err)
	}
	return extension, nil
}

func storeHostedAsset(
	reader io.Reader,
	originalName string,
	extension string,
	now time.Time,
	config Config,
) (hostedPath string, hostedURL string, retErr error) {
	hostedDir := filepath.Join(config.DataDir, "hosted")
	staged, err := os.CreateTemp(hostedDir, ".asset.tmp-")
	if err != nil {
		return "", "", fmt.Errorf("create staged hosted asset: %w", err)
	}
	stagedPath := staged.Name()
	publishedPath := ""
	assetCommitted := false
	defer func() {
		_ = staged.Close()
		_ = os.Remove(stagedPath)
		if !assetCommitted && publishedPath != "" {
			if err := os.Remove(publishedPath); err == nil {
				_ = syncDirectory(hostedDir)
			}
		}
	}()
	if err := staged.Chmod(0644); err != nil {
		return "", "", fmt.Errorf("set hosted asset permissions: %w", err)
	}

	written, err := io.Copy(staged, reader)
	if err != nil {
		return "", "", fmt.Errorf("copy asset to hosted storage: %w", err)
	}
	if err := staged.Sync(); err != nil {
		return "", "", fmt.Errorf("sync hosted asset: %w", err)
	}
	if err := staged.Close(); err != nil {
		return "", "", fmt.Errorf("close hosted asset: %w", err)
	}

	publishedPath, filename, err := publishStagedAsset(
		stagedPath,
		hostedDir,
		now.Format("20060102-1504"),
		extension,
	)
	if err != nil {
		return "", "", fmt.Errorf("publish hosted asset: %w", err)
	}
	hostedPath = publishedPath
	if err := os.Remove(stagedPath); err != nil {
		return "", "", fmt.Errorf("remove staged hosted asset: %w", err)
	}
	if err := syncDirectory(hostedDir); err != nil {
		return "", "", fmt.Errorf("sync hosted directory: %w", err)
	}

	hostedURL = fmt.Sprintf("%s/%s", strings.TrimRight(config.BaseURL, "/"), filename)
	metadata := ScreenshotMetadata{
		ID:           uuid.New().String(),
		OriginalName: originalName,
		Filename:     filename,
		URL:          hostedURL,
		Timestamp:    now,
		Size:         written,
		Preserve:     false,
	}
	metadataPath := filepath.Join(config.DataDir, "metadata", metadata.ID+".json")
	if err := saveMetadata(metadata, metadataPath); err != nil {
		return "", "", fmt.Errorf("save asset metadata: %w", err)
	}
	assetCommitted = true
	return hostedPath, hostedURL, nil
}

func publishStagedAsset(stagedPath, directory, stem, extension string) (string, string, error) {
	for collision := 0; ; collision++ {
		filename := stem + extension
		if collision > 0 {
			filename = fmt.Sprintf("%s-%d%s", stem, collision, extension)
		}
		path := filepath.Join(directory, filename)
		err := os.Link(stagedPath, path)
		if err == nil {
			return path, filename, nil
		}
		if !os.IsExist(err) {
			return "", "", err
		}
	}
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
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

	directory := filepath.Dir(path)
	temp, err := os.CreateTemp(directory, ".metadata.tmp-")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	committed := false
	defer func() {
		_ = temp.Close()
		if !committed {
			_ = os.Remove(tempPath)
		}
	}()
	if err := temp.Chmod(0644); err != nil {
		return err
	}
	if _, err := temp.Write(data); err != nil {
		return err
	}
	if err := temp.Sync(); err != nil {
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Link(tempPath, path); err != nil {
		return err
	}
	if err := os.Remove(tempPath); err != nil {
		_ = os.Remove(path)
		return err
	}
	if err := syncDirectory(directory); err != nil {
		_ = os.Remove(path)
		_ = syncDirectory(directory)
		return err
	}
	committed = true
	return nil
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

// NEW: Helper function to parse offset from URL path
func parseOffsetFromURL(urlPath string) int {
	parts := strings.Split(strings.Trim(urlPath, "/"), "/")

	// Handle URLs like "/hybrid/5" or "/stateless/10"
	if len(parts) >= 2 {
		if val, err := strconv.Atoi(parts[1]); err == nil {
			return val
		}
	}

	return 0 // default offset
}

// NEW: Try to lookup file via metadata (fast path)
func tryMetadataLookup(config Config, offset int) (ScreenshotMetadata, bool) {
	allMetadata := loadAllMetadata(config)

	if len(allMetadata) == 0 {
		log.Printf("🔍 Metadata lookup: No metadata files found")
		return ScreenshotMetadata{}, false
	}

	// Sort by timestamp descending (same as original logic)
	sort.Slice(allMetadata, func(i, j int) bool {
		return allMetadata[i].Timestamp.After(allMetadata[j].Timestamp)
	})

	if offset >= len(allMetadata) {
		log.Printf("🔍 Metadata lookup: Offset %d >= metadata count %d", offset, len(allMetadata))
		return ScreenshotMetadata{}, false
	}

	return allMetadata[offset], true
}

// NEW: Try to lookup file via direct filesystem scan (bulletproof path)
func tryFilesystemLookup(config Config, offset int) (string, bool) {
	files := scanHostedFilesForLatest(config)

	if len(files) == 0 {
		log.Printf("🔍 Filesystem lookup: No files found in hosted directory")
		return "", false
	}

	if offset >= len(files) {
		log.Printf("🔍 Filesystem lookup: Offset %d >= file count %d", offset, len(files))
		return "", false
	}

	filename := files[offset]
	url := fmt.Sprintf("%s/%s", config.BaseURL, filename)
	return url, true
}

// NEW: Scan hosted directory for files, return sorted by modification time (latest first)
func scanHostedFilesForLatest(config Config) []string {
	hostedDir := filepath.Join(config.DataDir, "hosted")

	entries, err := os.ReadDir(hostedDir)
	if err != nil {
		log.Printf("⚠️  Error reading hosted directory: %v", err)
		return []string{}
	}

	type FileInfo struct {
		Name    string
		ModTime time.Time
	}

	var files []FileInfo

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		// Only include image/gif files
		if !isImageFile(entry.Name()) {
			continue
		}

		fullPath := filepath.Join(hostedDir, entry.Name())
		fileInfo, err := os.Stat(fullPath)
		if err != nil {
			log.Printf("⚠️  Error getting file info for %s: %v", entry.Name(), err)
			continue
		}

		files = append(files, FileInfo{
			Name:    entry.Name(),
			ModTime: fileInfo.ModTime(),
		})
	}

	// Sort by modification time descending (latest first)
	sort.Slice(files, func(i, j int) bool {
		return files[i].ModTime.After(files[j].ModTime)
	})

	// Extract just the filenames
	var result []string
	for _, file := range files {
		result = append(result, file.Name)
	}

	log.Printf("🔍 Filesystem scan found %d files", len(result))
	return result
}

// NEW: Count actual files in hosted directory
func countActualFiles(config Config) int {
	return len(scanHostedFilesForLatest(config))
}

// NEW: Load all metadata files (extracted from original handleLatest)
func loadAllMetadata(config Config) []ScreenshotMetadata {
	metadataDir := filepath.Join(config.DataDir, "metadata")
	files, err := os.ReadDir(metadataDir)
	if err != nil {
		log.Printf("⚠️  Error reading metadata directory: %v", err)
		return []ScreenshotMetadata{}
	}

	var allMetadata []ScreenshotMetadata

	for _, file := range files {
		if strings.HasSuffix(file.Name(), ".json") {
			filePath := filepath.Join(metadataDir, file.Name())
			data, err := os.ReadFile(filePath)
			if err != nil {
				log.Printf("⚠️  Failed to read metadata file %s: %v", file.Name(), err)
				continue
			}

			var metadata ScreenshotMetadata
			if err := json.Unmarshal(data, &metadata); err != nil {
				log.Printf("⚠️  Failed to unmarshal metadata file %s: %v", file.Name(), err)
				continue
			}

			allMetadata = append(allMetadata, metadata)
		}
	}

	return allMetadata
}

// NEW: Check metadata consistency against actual files
func checkMetadataConsistency(config Config) []string {
	var issues []string

	// Get all metadata
	allMetadata := loadAllMetadata(config)
	hostedDir := filepath.Join(config.DataDir, "hosted")

	// Check if metadata files have corresponding hosted files
	for _, metadata := range allMetadata {
		hostedPath := filepath.Join(hostedDir, metadata.Filename)
		if !fileExists(hostedPath) {
			issues = append(issues, fmt.Sprintf("Metadata references missing file: %s", metadata.Filename))
		}
	}

	// Check if hosted files have corresponding metadata
	actualFiles := scanHostedFilesForLatest(config)
	metadataFilenames := make(map[string]bool)

	for _, metadata := range allMetadata {
		metadataFilenames[metadata.Filename] = true
	}

	for _, filename := range actualFiles {
		if !metadataFilenames[filename] {
			issues = append(issues, fmt.Sprintf("Hosted file missing metadata: %s", filename))
		}
	}

	log.Printf("🔍 Consistency check: Found %d issues", len(issues))
	return issues
}
