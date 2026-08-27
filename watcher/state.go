package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"
)

const (
	defaultStateDir              = "/data/state"
	lastScreenshotMarker         = "last-screenshot"
	latestURLMarker              = "latest-url"
	defaultClipboardPollInterval = 2 * time.Second
	defaultClipboardTimeout      = 2 * time.Second
)

type clipboardWriter func(context.Context, string) error

type ClipboardBridgeOptions struct {
	StateDir     string
	PollInterval time.Duration
	Copy         clipboardWriter
}

func stateDirForConfig(config Config) string {
	if config.StateDir != "" {
		return config.StateDir
	}
	return getEnv("SSBNK_STATE_DIR", defaultStateDir)
}

// publishIngestionState makes host integrations data-driven. The public service
// never receives a compositor socket; it only publishes state for the isolated
// clipboard bridge. State failures are intentionally non-fatal to ingestion.
func publishIngestionState(config Config, hostedPath, url string) {
	stateDir := stateDirForConfig(config)
	if err := writeIngestionState(stateDir, filepath.Base(hostedPath), url); err != nil {
		log.Printf("Warning: Failed to publish host-integration state: %v", err)
	}
}

func writeIngestionState(stateDir, filename, url string) error {
	if filepath.Base(filename) != filename || filename == "." || filename == "" {
		return fmt.Errorf("invalid screenshot filename %q", filename)
	}
	if strings.TrimSpace(url) == "" {
		return errors.New("latest URL is empty")
	}
	if err := os.MkdirAll(stateDir, 0755); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}

	// Write the image marker first and the URL trigger second. Each marker is
	// atomic, and a bridge reacting to latest-url always sees last-screenshot.
	if err := atomicWriteMarker(filepath.Join(stateDir, lastScreenshotMarker), filename); err != nil {
		return fmt.Errorf("write last screenshot marker: %w", err)
	}
	if err := atomicWriteMarker(filepath.Join(stateDir, latestURLMarker), strings.TrimSpace(url)); err != nil {
		return fmt.Errorf("write latest URL marker: %w", err)
	}
	return nil
}

func atomicWriteMarker(path, value string) (retErr error) {
	dir := filepath.Dir(path)
	temp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	defer func() {
		_ = temp.Close()
		if retErr != nil {
			_ = os.Remove(tempName)
		}
	}()

	if err := temp.Chmod(0644); err != nil {
		return err
	}
	if _, err := io.WriteString(temp, value+"\n"); err != nil {
		return err
	}
	if err := temp.Sync(); err != nil {
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tempName, path); err != nil {
		return err
	}

	// Best-effort directory sync makes the rename durable on local Linux
	// filesystems without turning unsupported filesystems into ingestion errors.
	if dirHandle, err := os.Open(dir); err == nil {
		_ = dirHandle.Sync()
		_ = dirHandle.Close()
	}
	return nil
}

func clipboardBridgeOptionsFromEnv() ClipboardBridgeOptions {
	pollInterval := defaultClipboardPollInterval
	if raw := os.Getenv("SSBNK_CLIPBOARD_POLL_INTERVAL"); raw != "" {
		if parsed, err := time.ParseDuration(raw); err == nil && parsed > 0 {
			pollInterval = parsed
		} else {
			log.Printf("Warning: Invalid SSBNK_CLIPBOARD_POLL_INTERVAL=%q; using %s", raw, pollInterval)
		}
	}

	timeout := defaultClipboardTimeout
	if raw := os.Getenv("SSBNK_CLIPBOARD_TIMEOUT"); raw != "" {
		if parsed, err := time.ParseDuration(raw); err == nil && parsed > 0 {
			timeout = parsed
		} else {
			log.Printf("Warning: Invalid SSBNK_CLIPBOARD_TIMEOUT=%q; using %s", raw, timeout)
		}
	}

	return ClipboardBridgeOptions{
		StateDir:     getEnv("SSBNK_STATE_DIR", defaultStateDir),
		PollInterval: pollInterval,
		Copy: func(ctx context.Context, text string) error {
			return runWLClipboard(ctx, timeout, text)
		},
	}
}

func runClipboardBridge(ctx context.Context, options ClipboardBridgeOptions) error {
	if options.StateDir == "" {
		return errors.New("state directory is empty")
	}
	if options.PollInterval <= 0 {
		return errors.New("clipboard poll interval must be positive")
	}
	if options.Copy == nil {
		return errors.New("clipboard writer is not configured")
	}
	if err := os.MkdirAll(options.StateDir, 0755); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return fmt.Errorf("create state watcher: %w", err)
	}
	defer watcher.Close()
	if err := watcher.Add(options.StateDir); err != nil {
		return fmt.Errorf("watch state directory: %w", err)
	}

	latestPath := filepath.Join(options.StateDir, latestURLMarker)
	lastCopied := ""
	copyLatest := func() {
		contents, err := os.ReadFile(latestPath)
		if err != nil {
			if !os.IsNotExist(err) {
				log.Printf("Clipboard bridge: failed to read latest URL: %v", err)
			}
			return
		}
		latest := strings.TrimSpace(string(contents))
		if latest == "" || latest == lastCopied {
			return
		}
		if err := options.Copy(ctx, latest); err != nil {
			log.Printf("Clipboard bridge: wl-copy failed: %v", err)
			return
		}
		lastCopied = latest
		log.Printf("Clipboard bridge: copied latest URL")
	}

	// Catch an event published before the watcher process came up.
	copyLatest()
	poll := time.NewTicker(options.PollInterval)
	defer poll.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case event, ok := <-watcher.Events:
			if !ok {
				return errors.New("state watcher closed unexpectedly")
			}
			if filepath.Clean(event.Name) == filepath.Clean(latestPath) &&
				event.Op&(fsnotify.Create|fsnotify.Write|fsnotify.Rename) != 0 {
				copyLatest()
			}
		case err, ok := <-watcher.Errors:
			if !ok {
				return errors.New("state watcher error channel closed unexpectedly")
			}
			log.Printf("Clipboard bridge watcher error: %v", err)
		case <-poll.C:
			copyLatest()
		}
	}
}

func runWLClipboard(parent context.Context, timeout time.Duration, text string) error {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "wl-copy")
	cmd.Stdin = strings.NewReader(text)
	if err := cmd.Run(); err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("wl-copy timed out after %s", timeout)
		}
		return fmt.Errorf("run wl-copy: %w", err)
	}
	return nil
}
