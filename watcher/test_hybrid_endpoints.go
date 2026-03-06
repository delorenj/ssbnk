package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Test helper to create a temporary config for testing
func createTestConfig(t *testing.T) (Config, string) {
	tempDir := t.TempDir()
	
	config := Config{
		ScreenshotDir: filepath.Join(tempDir, "screenshots"),
		ScreencastDir: filepath.Join(tempDir, "screencasts"),
		DataDir:       filepath.Join(tempDir, "data"),
		BaseURL:       "http://test.example.com",
	}
	
	// Create required directories
	dirs := []string{
		filepath.Join(config.DataDir, "hosted"),
		filepath.Join(config.DataDir, "metadata"),
		config.ScreenshotDir,
		config.ScreencastDir,
	}
	
	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0755); err != nil {
			t.Fatalf("Failed to create test directory %s: %v", dir, err)
		}
	}
	
	return config, tempDir
}

// Helper to create test files and metadata
func createTestData(t *testing.T, config Config) {
	hostedDir := filepath.Join(config.DataDir, "hosted")
	metadataDir := filepath.Join(config.DataDir, "metadata")
	
	// Create test image files with different timestamps
	testFiles := []struct {
		filename string
		delay    time.Duration
	}{
		{"20240101-1200.png", 0},
		{"20240101-1300.png", time.Second},
		{"20240101-1400.gif", 2 * time.Second},
	}
	
	for i, testFile := range testFiles {
		// Create the hosted file
		time.Sleep(testFile.delay) // Ensure different modification times
		hostedPath := filepath.Join(hostedDir, testFile.filename)
		content := fmt.Sprintf("test image content %d", i)
		if err := os.WriteFile(hostedPath, []byte(content), 0644); err != nil {
			t.Fatalf("Failed to create test file %s: %v", testFile.filename, err)
		}
		
		// Create corresponding metadata
		metadata := ScreenshotMetadata{
			ID:           fmt.Sprintf("test-id-%d", i),
			OriginalName: fmt.Sprintf("original-%d.png", i),
			Filename:     testFile.filename,
			URL:          fmt.Sprintf("%s/%s", config.BaseURL, testFile.filename),
			Timestamp:    time.Now().Add(-time.Duration(len(testFiles)-i) * time.Hour), // Older files have earlier timestamps
			Description:  fmt.Sprintf("Test image %d", i),
			Preserve:     false,
			Size:         int64(len(content)),
		}
		
		metadataPath := filepath.Join(metadataDir, fmt.Sprintf("%s.json", metadata.ID))
		if err := saveMetadata(metadata, metadataPath); err != nil {
			t.Fatalf("Failed to save test metadata: %v", err)
		}
	}
}

func TestHybridEndpoint_WithValidMetadata(t *testing.T) {
	config, _ := createTestConfig(t)
	createTestData(t, config)
	
	// Test hybrid endpoint with offset 0 (latest)
	req := httptest.NewRequest("GET", "/hybrid/0", nil)
	w := httptest.NewRecorder()
	
	handleLatestHybrid(w, req, config)
	
	if w.Code != http.StatusFound {
		t.Errorf("Expected status %d, got %d", http.StatusFound, w.Code)
	}
	
	location := w.Header().Get("Location")
	if location == "" {
		t.Error("Expected redirect location, got empty")
	}
	
	log.Printf("✅ Hybrid endpoint test passed - redirected to: %s", location)
}

func TestStatelessEndpoint_FilesystemOnly(t *testing.T) {
	config, _ := createTestConfig(t)
	
	// Create files WITHOUT metadata
	hostedDir := filepath.Join(config.DataDir, "hosted")
	testFiles := []string{"test1.png", "test2.gif", "test3.png"}
	
	for i, filename := range testFiles {
		time.Sleep(10 * time.Millisecond) // Ensure different mod times
		filePath := filepath.Join(hostedDir, filename)
		content := fmt.Sprintf("test content %d", i)
		if err := os.WriteFile(filePath, []byte(content), 0644); err != nil {
			t.Fatalf("Failed to create test file: %v", err)
		}
	}
	
	// Test stateless endpoint
	req := httptest.NewRequest("GET", "/stateless/0", nil)
	w := httptest.NewRecorder()
	
	handleLatestStateless(w, req, config)
	
	if w.Code != http.StatusFound {
		t.Errorf("Expected status %d, got %d", http.StatusFound, w.Code)
	}
	
	location := w.Header().Get("Location")
	if location == "" {
		t.Error("Expected redirect location, got empty")
	}
	
	log.Printf("✅ Stateless endpoint test passed - redirected to: %s", location)
}

func TestHealthCheckEndpoint(t *testing.T) {
	config, _ := createTestConfig(t)
	createTestData(t, config)
	
	req := httptest.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()
	
	handleHealthCheck(w, req, config)
	
	if w.Code != http.StatusOK {
		t.Errorf("Expected status %d, got %d", http.StatusOK, w.Code)
	}
	
	// Parse response
	var health map[string]interface{}
	body, _ := io.ReadAll(w.Body)
	if err := json.Unmarshal(body, &health); err != nil {
		t.Fatalf("Failed to parse health response: %v", err)
	}
	
	// Check required fields
	if health["status"] == nil {
		t.Error("Health response missing status field")
	}
	if health["metadata_count"] == nil {
		t.Error("Health response missing metadata_count field")
	}
	if health["actual_file_count"] == nil {
		t.Error("Health response missing actual_file_count field")
	}
	
	log.Printf("✅ Health check test passed - status: %s", health["status"])
	log.Printf("   Metadata count: %v, Actual files: %v", health["metadata_count"], health["actual_file_count"])
}

func TestHybridFallback_MetadataMissing(t *testing.T) {
	config, _ := createTestConfig(t)
	
	// Create only hosted files, no metadata
	hostedDir := filepath.Join(config.DataDir, "hosted")
	filename := "fallback-test.png"
	filePath := filepath.Join(hostedDir, filename)
	
	if err := os.WriteFile(filePath, []byte("fallback test content"), 0644); err != nil {
		t.Fatalf("Failed to create test file: %v", err)
	}
	
	// Test hybrid endpoint - should fall back to filesystem scan
	req := httptest.NewRequest("GET", "/hybrid/0", nil)
	w := httptest.NewRecorder()
	
	handleLatestHybrid(w, req, config)
	
	if w.Code != http.StatusFound {
		t.Errorf("Expected status %d, got %d", http.StatusFound, w.Code)
	}
	
	location := w.Header().Get("Location")
	expectedURL := fmt.Sprintf("%s/%s", config.BaseURL, filename)
	
	if location != expectedURL {
		t.Errorf("Expected redirect to %s, got %s", expectedURL, location)
	}
	
	log.Printf("✅ Hybrid fallback test passed - fell back to filesystem scan")
}

func TestOffsetParsing(t *testing.T) {
	tests := []struct {
		path     string
		expected int
	}{
		{"/hybrid", 0},
		{"/hybrid/", 0},
		{"/hybrid/5", 5},
		{"/stateless/10", 10},
		{"/health", 0},
		{"/invalid/path", 0},
	}
	
	for _, test := range tests {
		result := parseOffsetFromURL(test.path)
		if result != test.expected {
			t.Errorf("parseOffsetFromURL(%s) = %d, expected %d", test.path, result, test.expected)
		}
	}
	
	log.Printf("✅ Offset parsing tests passed")
}

// Simple benchmark to ensure performance is reasonable
func BenchmarkHybridEndpoint(b *testing.B) {
	config, _ := createTestConfig(&testing.T{})
	createTestData(&testing.T{}, config)
	
	b.ResetTimer()
	
	for i := 0; i < b.N; i++ {
		req := httptest.NewRequest("GET", "/hybrid/0", nil)
		w := httptest.NewRecorder()
		handleLatestHybrid(w, req, config)
	}
}

func BenchmarkStatelessEndpoint(b *testing.B) {
	config, _ := createTestConfig(&testing.T{})
	
	// Create files without metadata for stateless test
	hostedDir := filepath.Join(config.DataDir, "hosted")
	for i := 0; i < 10; i++ {
		filename := fmt.Sprintf("bench-test-%d.png", i)
		filePath := filepath.Join(hostedDir, filename)
		os.WriteFile(filePath, []byte(fmt.Sprintf("content %d", i)), 0644)
	}
	
	b.ResetTimer()
	
	for i := 0; i < b.N; i++ {
		req := httptest.NewRequest("GET", "/stateless/0", nil)
		w := httptest.NewRecorder()
		handleLatestStateless(w, req, config)
	}
}