package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
)

// ScreenshotMetadata represents metadata for a screenshot
type ScreenshotMetadata struct {
	ID           string    `json:"id"`
	OriginalName string    `json:"original_name"`
	Filename     string    `json:"filename"`
	URL          string    `json:"url"`
	Timestamp    time.Time `json:"timestamp"`
	Size         int64     `json:"size"`
	Preserve     bool      `json:"preserve"`
}

func main() {
	hostedDir := "/data/hosted"
	metadataDir := "/data/metadata"
	baseURL := "https://ss.delo.sh"

	if len(os.Args) > 1 && os.Args[1] == "--help" {
		fmt.Println("Usage: generate-missing-metadata")
		fmt.Println("Generates metadata files for existing images that lack them")
		return
	}

	// Ensure metadata directory exists
	if err := os.MkdirAll(metadataDir, 0755); err != nil {
		log.Fatalf("Failed to create metadata directory: %v", err)
	}

	// Get list of existing metadata files
	existingMetadata := make(map[string]bool)
	err := filepath.Walk(metadataDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if strings.HasSuffix(strings.ToLower(info.Name()), ".json") {
			// Read the metadata to get the filename
			data, err := os.ReadFile(path)
			if err != nil {
				log.Printf("Warning: Failed to read metadata file %s: %v", path, err)
				return nil
			}
			var metadata ScreenshotMetadata
			if err := json.Unmarshal(data, &metadata); err != nil {
				log.Printf("Warning: Failed to parse metadata file %s: %v", path, err)
				return nil
			}
			existingMetadata[metadata.Filename] = true
		}
		return nil
	})
	if err != nil {
		log.Fatalf("Failed to scan existing metadata: %v", err)
	}

	log.Printf("Found %d existing metadata entries", len(existingMetadata))

	// Scan hosted directory for images
	var generated int
	err = filepath.Walk(hostedDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		// Skip directories
		if info.IsDir() {
			return nil
		}

		// Check if it's an image file
		ext := strings.ToLower(filepath.Ext(info.Name()))
		if ext != ".png" && ext != ".jpg" && ext != ".jpeg" && ext != ".gif" && ext != ".webp" {
			return nil
		}

		// Skip if metadata already exists
		if existingMetadata[info.Name()] {
			log.Printf("Metadata already exists for: %s", info.Name())
			return nil
		}

		// Generate metadata
		metadata := ScreenshotMetadata{
			ID:           uuid.New().String(),
			OriginalName: info.Name(), // We don't have the original name, use filename
			Filename:     info.Name(),
			URL:          fmt.Sprintf("%s/%s", baseURL, info.Name()),
			Timestamp:    info.ModTime(), // Use file modification time as timestamp
			Size:         info.Size(),
			Preserve:     false,
		}

		// Save metadata
		metadataPath := filepath.Join(metadataDir, fmt.Sprintf("%s.json", metadata.ID))
		data, err := json.MarshalIndent(metadata, "", "  ")
		if err != nil {
			return fmt.Errorf("failed to marshal metadata for %s: %w", info.Name(), err)
		}

		if err := os.WriteFile(metadataPath, data, 0644); err != nil {
			return fmt.Errorf("failed to save metadata for %s: %w", info.Name(), err)
		}

		log.Printf("Generated metadata for: %s (ID: %s)", info.Name(), metadata.ID)
		generated++
		return nil
	})

	if err != nil {
		log.Fatalf("Failed to process hosted files: %v", err)
	}

	log.Printf("Successfully generated metadata for %d files", generated)
}