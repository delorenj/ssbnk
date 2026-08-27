package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newCleanupOptions(t *testing.T, now time.Time) CleanupOptions {
	t.Helper()
	dataDir := filepath.Join(t.TempDir(), "data")
	for _, name := range []string{"hosted", "metadata", "archive", "state"} {
		if err := os.MkdirAll(filepath.Join(dataDir, name), 0755); err != nil {
			t.Fatalf("create %s: %v", name, err)
		}
	}
	return CleanupOptions{
		DataDir:              dataDir,
		StateDir:             filepath.Join(dataDir, "state"),
		BaseURL:              "https://ss.test",
		HostedRetentionDays:  30,
		ArchiveRetentionDays: 30,
		Now:                  now,
		Output:               &bytes.Buffer{},
	}
}

func writeTestHostedFile(t *testing.T, options CleanupOptions, name string, modified time.Time) string {
	t.Helper()
	path := filepath.Join(options.DataDir, "hosted", name)
	if err := os.WriteFile(path, []byte("image:"+name), 0644); err != nil {
		t.Fatalf("write hosted file: %v", err)
	}
	if err := os.Chtimes(path, modified, modified); err != nil {
		t.Fatalf("set hosted file time: %v", err)
	}
	return path
}

func writeTestMetadata(t *testing.T, directory, id, filename string, preserve bool) string {
	t.Helper()
	metadata := ScreenshotMetadata{
		ID:           id,
		OriginalName: filename,
		Filename:     filename,
		URL:          "https://ss.test/" + filename,
		Timestamp:    time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		Preserve:     preserve,
		Size:         10,
	}
	path := filepath.Join(directory, id+".json")
	if err := saveMetadata(metadata, path); err != nil {
		t.Fatalf("write metadata: %v", err)
	}
	return path
}

func TestCleanupArchivesAndPrunesSafely(t *testing.T) {
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	options := newCleanupOptions(t, now)
	hostedDir := filepath.Join(options.DataDir, "hosted")
	metadataDir := filepath.Join(options.DataDir, "metadata")
	archiveDir := filepath.Join(options.DataDir, "archive")

	oldPath := writeTestHostedFile(t, options, "old.png", now.Add(-31*24*time.Hour))
	preservedPath := writeTestHostedFile(t, options, "preserved.png", now.Add(-90*24*time.Hour))
	newPath := writeTestHostedFile(t, options, "new.png", now.Add(-24*time.Hour))
	oldMetadata := writeTestMetadata(t, metadataDir, "old", "old.png", false)
	preservedMetadata := writeTestMetadata(t, metadataDir, "preserved", "preserved.png", true)
	newMetadata := writeTestMetadata(t, metadataDir, "new", "new.png", false)
	orphanMetadata := writeTestMetadata(t, metadataDir, "orphan", "missing.png", false)
	unknownMetadata := writeTestMetadata(t, metadataDir, "unknown-ref", "unknown.png", false)

	oldArchive := filepath.Join(archiveDir, "2026-06-01")
	if err := os.MkdirAll(oldArchive, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(oldArchive, "expired.png"), []byte("expired"), 0644); err != nil {
		t.Fatal(err)
	}
	writeTestMetadata(t, oldArchive, "expired", "expired.png", false)

	// Names that are not strict YYYY-MM-DD archive dates are never pruned or
	// parsed as managed archives.
	unknownArchive := filepath.Join(archiveDir, "manual-import")
	if err := os.MkdirAll(unknownArchive, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(unknownArchive, "unknown.png"), []byte("keep"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(unknownArchive, "malformed.json"), []byte("not managed"), 0644); err != nil {
		t.Fatal(err)
	}

	if err := writeIngestionState(options.StateDir, "old.png", "https://ss.test/old.png"); err != nil {
		t.Fatal(err)
	}

	result, err := runCleanup(options)
	if err != nil {
		t.Fatalf("run cleanup: %v", err)
	}
	if result.ArchivedFiles != 1 || result.ArchivedMetadata != 1 {
		t.Fatalf("unexpected archive counts: %+v", result)
	}
	if result.DeletedArchiveDirs != 1 || result.RemovedOrphanedMetadata != 1 {
		t.Fatalf("unexpected prune counts: %+v", result)
	}
	if !result.RepairedStateMarkers {
		t.Fatal("expected stale state markers to be repaired")
	}

	todayArchive := filepath.Join(archiveDir, "2026-08-27")
	assertPathMissing(t, oldPath)
	assertPathExists(t, filepath.Join(todayArchive, "old.png"))
	assertPathMissing(t, oldMetadata)
	assertPathExists(t, filepath.Join(todayArchive, "old.json"))
	assertPathExists(t, preservedPath)
	assertPathExists(t, newPath)
	assertPathExists(t, preservedMetadata)
	assertPathExists(t, newMetadata)
	assertPathExists(t, unknownMetadata)
	assertPathMissing(t, orphanMetadata)
	assertPathMissing(t, oldArchive)
	assertPathExists(t, unknownArchive)

	last, err := readMarker(filepath.Join(options.StateDir, lastScreenshotMarker))
	if err != nil || last != "new.png" {
		t.Fatalf("last screenshot marker = %q, %v", last, err)
	}
	latest, err := readMarker(filepath.Join(options.StateDir, latestURLMarker))
	if err != nil || latest != "https://ss.test/new.png" {
		t.Fatalf("latest URL marker = %q, %v", latest, err)
	}
	_ = hostedDir // documents the root whose contents were asserted above
}

func TestCleanupMalformedMetadataFailsBeforeMutation(t *testing.T) {
	tests := []struct {
		name     string
		contents string
	}{
		{name: "invalid JSON", contents: `{"filename":`},
		{name: "unknown field", contents: `{"filename":"old.png","unexpected":true}`},
		{name: "trailing value", contents: `{"filename":"old.png"} {}`},
		{name: "unsafe filename", contents: `{"filename":"../old.png"}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
			options := newCleanupOptions(t, now)
			oldPath := writeTestHostedFile(t, options, "old.png", now.Add(-90*24*time.Hour))
			badPath := filepath.Join(options.DataDir, "metadata", "bad.json")
			if err := os.WriteFile(badPath, []byte(test.contents), 0644); err != nil {
				t.Fatal(err)
			}

			_, err := runCleanup(options)
			if err == nil || !strings.Contains(err.Error(), "metadata") {
				t.Fatalf("expected metadata error, got %v", err)
			}
			assertPathExists(t, oldPath)
			assertPathExists(t, badPath)
			assertPathMissing(t, filepath.Join(options.DataDir, "archive", "2026-08-27"))
		})
	}
}

func TestCleanupDryRunDoesNotMutate(t *testing.T) {
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	options := newCleanupOptions(t, now)
	options.DryRun = true
	oldPath := writeTestHostedFile(t, options, "old.png", now.Add(-90*24*time.Hour))
	metadataPath := writeTestMetadata(t, filepath.Join(options.DataDir, "metadata"), "old", "old.png", false)

	result, err := runCleanup(options)
	if err != nil {
		t.Fatal(err)
	}
	if result.ArchivedFiles != 1 || result.ArchivedMetadata != 1 {
		t.Fatalf("unexpected plan: %+v", result)
	}
	assertPathExists(t, oldPath)
	assertPathExists(t, metadataPath)
	assertPathMissing(t, filepath.Join(options.DataDir, "archive", "2026-08-27"))
	assertPathMissing(t, filepath.Join(options.StateDir, latestURLMarker))
}

func TestCleanupCollisionFailsWithoutMutation(t *testing.T) {
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	options := newCleanupOptions(t, now)
	oldPath := writeTestHostedFile(t, options, "old.png", now.Add(-90*24*time.Hour))
	todayArchive := filepath.Join(options.DataDir, "archive", "2026-08-27")
	if err := os.MkdirAll(todayArchive, 0755); err != nil {
		t.Fatal(err)
	}
	collisionPath := filepath.Join(todayArchive, "old.png")
	if err := os.WriteFile(collisionPath, []byte("existing"), 0644); err != nil {
		t.Fatal(err)
	}

	_, err := runCleanup(options)
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("expected collision error, got %v", err)
	}
	assertPathExists(t, oldPath)
	contents, readErr := os.ReadFile(collisionPath)
	if readErr != nil || string(contents) != "existing" {
		t.Fatalf("collision target changed: %q, %v", contents, readErr)
	}
}

func TestCleanupLockPreventsConcurrentRun(t *testing.T) {
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	options := newCleanupOptions(t, now)
	release, err := acquireCleanupLock(options.DataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer release()

	_, err = runCleanup(options)
	if err == nil || !strings.Contains(err.Error(), "already running") {
		t.Fatalf("expected concurrent cleanup error, got %v", err)
	}
}

func TestCleanupRetentionEnvironmentPrecedence(t *testing.T) {
	t.Setenv("SSBNK_HOSTED_RETENTION_DAYS", "")
	t.Setenv("SSBNK_RETENTION_DAYS", "17")
	t.Setenv("SSBNK_ARCHIVE_RETENTION_DAYS", "9")
	options, err := cleanupOptionsFromEnv(&bytes.Buffer{})
	if err != nil {
		t.Fatal(err)
	}
	if options.HostedRetentionDays != 17 || options.ArchiveRetentionDays != 9 {
		t.Fatalf("unexpected retention options: %+v", options)
	}

	t.Setenv("SSBNK_HOSTED_RETENTION_DAYS", "4")
	options, err = cleanupOptionsFromEnv(&bytes.Buffer{})
	if err != nil {
		t.Fatal(err)
	}
	if options.HostedRetentionDays != 4 {
		t.Fatalf("hosted retention did not override legacy value: %+v", options)
	}

	t.Setenv("SSBNK_ARCHIVE_RETENTION_DAYS", "-1")
	_, err = cleanupOptionsFromEnv(&bytes.Buffer{})
	if err == nil {
		t.Fatal("expected invalid archive retention to fail")
	}
}

func assertPathExists(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("expected %s to exist: %v", path, err)
	}
}

func assertPathMissing(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expected %s to be absent, got %v", path, err)
	}
}
