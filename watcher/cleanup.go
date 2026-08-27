package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const defaultRetentionDays = 30

type CleanupOptions struct {
	DataDir              string
	StateDir             string
	BaseURL              string
	HostedRetentionDays  int
	ArchiveRetentionDays int
	DryRun               bool
	Now                  time.Time
	Output               io.Writer
}

type CleanupResult struct {
	ArchivedFiles           int
	ArchivedMetadata        int
	DeletedArchiveDirs      int
	RemovedOrphanedMetadata int
	RepairedStateMarkers    bool
	WouldRepairStateMarkers bool
}

type metadataFile struct {
	Path     string
	Metadata ScreenshotMetadata
}

type hostedFile struct {
	Path    string
	Name    string
	ModTime time.Time
}

type moveAction struct {
	Source      string
	Destination string
}

type cleanupPlan struct {
	ArchiveToday      string
	FileMoves         []moveAction
	MetadataMoves     []moveAction
	ArchiveDeletes    []string
	OrphanDeletes     []string
	RemainingHosted   map[string]hostedFile
	RemainingMetadata []metadataFile
}

func runCleanupCommand(args []string, output io.Writer) error {
	options, err := cleanupOptionsFromEnv(output)
	if err != nil {
		return err
	}

	flags := flag.NewFlagSet("cleanup", flag.ContinueOnError)
	flags.SetOutput(output)
	flags.BoolVar(&options.DryRun, "dry-run", false, "print cleanup actions without changing data")
	flags.Usage = func() {
		fmt.Fprintln(output, "Usage: ssbnk cleanup [--dry-run]")
	}
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("cleanup does not accept positional arguments: %s", strings.Join(flags.Args(), " "))
	}

	result, err := runCleanup(options)
	if err != nil {
		return err
	}
	mode := "completed"
	if options.DryRun {
		mode = "dry run"
	}
	fmt.Fprintf(output,
		"cleanup %s: archived_files=%d archived_metadata=%d deleted_archive_dirs=%d removed_orphaned_metadata=%d repaired_state=%t\n",
		mode,
		result.ArchivedFiles,
		result.ArchivedMetadata,
		result.DeletedArchiveDirs,
		result.RemovedOrphanedMetadata,
		result.RepairedStateMarkers || result.WouldRepairStateMarkers,
	)
	return nil
}

func cleanupOptionsFromEnv(output io.Writer) (CleanupOptions, error) {
	hostedRaw := os.Getenv("SSBNK_HOSTED_RETENTION_DAYS")
	if hostedRaw == "" {
		hostedRaw = getEnv("SSBNK_RETENTION_DAYS", strconv.Itoa(defaultRetentionDays))
	}
	hostedDays, err := parseRetentionDays("hosted", hostedRaw)
	if err != nil {
		return CleanupOptions{}, err
	}
	archiveDays, err := parseRetentionDays(
		"archive",
		getEnv("SSBNK_ARCHIVE_RETENTION_DAYS", strconv.Itoa(defaultRetentionDays)),
	)
	if err != nil {
		return CleanupOptions{}, err
	}

	return CleanupOptions{
		DataDir:              getEnv("SSBNK_DATA_DIR", "/data"),
		StateDir:             getEnv("SSBNK_STATE_DIR", defaultStateDir),
		BaseURL:              getEnv("SSBNK_URL", "https://ss.yourdomain.com"),
		HostedRetentionDays:  hostedDays,
		ArchiveRetentionDays: archiveDays,
		Now:                  time.Now(),
		Output:               output,
	}, nil
}

func parseRetentionDays(policy, raw string) (int, error) {
	days, err := strconv.Atoi(raw)
	if err != nil || days < 0 {
		return 0, fmt.Errorf("%s retention days must be a non-negative integer, got %q", policy, raw)
	}
	return days, nil
}

func runCleanup(options CleanupOptions) (CleanupResult, error) {
	if options.DataDir == "" {
		return CleanupResult{}, errors.New("data directory is empty")
	}
	if options.StateDir == "" {
		options.StateDir = filepath.Join(options.DataDir, "state")
	}
	if options.HostedRetentionDays < 0 || options.ArchiveRetentionDays < 0 {
		return CleanupResult{}, errors.New("retention days must be non-negative")
	}
	if options.Now.IsZero() {
		options.Now = time.Now()
	}
	if options.Output == nil {
		options.Output = io.Discard
	}

	release, err := acquireCleanupLock(options.DataDir)
	if err != nil {
		return CleanupResult{}, err
	}
	defer release()

	// Planning parses and validates every metadata record that cleanup may move
	// or delete. No filesystem mutation occurs until the full plan is valid.
	plan, err := buildCleanupPlan(options)
	if err != nil {
		return CleanupResult{}, err
	}

	result := CleanupResult{
		ArchivedFiles:           len(plan.FileMoves),
		ArchivedMetadata:        len(plan.MetadataMoves),
		DeletedArchiveDirs:      len(plan.ArchiveDeletes),
		RemovedOrphanedMetadata: len(plan.OrphanDeletes),
	}
	result.WouldRepairStateMarkers = stateMarkersNeedRepair(options.StateDir, plan.RemainingHosted)

	if options.DryRun {
		printCleanupPlan(options.Output, plan)
		return result, nil
	}

	createdArchiveToday := false
	if len(plan.FileMoves)+len(plan.MetadataMoves) > 0 {
		if _, err := os.Stat(plan.ArchiveToday); os.IsNotExist(err) {
			createdArchiveToday = true
		} else if err != nil {
			return CleanupResult{}, fmt.Errorf("inspect today's archive directory: %w", err)
		}
		if err := os.MkdirAll(plan.ArchiveToday, 0755); err != nil {
			return CleanupResult{}, fmt.Errorf("create today's archive directory: %w", err)
		}
	}

	moves := append(append([]moveAction(nil), plan.FileMoves...), plan.MetadataMoves...)
	completedMoves := make([]moveAction, 0, len(moves))
	for _, action := range moves {
		if err := moveFileNoReplace(action.Source, action.Destination); err != nil {
			rollbackMoves(completedMoves, options.Output)
			if createdArchiveToday {
				_ = os.Remove(plan.ArchiveToday)
			}
			return CleanupResult{}, fmt.Errorf("move %s to archive: %w", action.Source, err)
		}
		completedMoves = append(completedMoves, action)
	}

	for _, archiveDir := range plan.ArchiveDeletes {
		if err := os.RemoveAll(archiveDir); err != nil {
			return CleanupResult{}, fmt.Errorf("delete archive directory %s: %w", archiveDir, err)
		}
	}
	for _, metadataPath := range plan.OrphanDeletes {
		if err := os.Remove(metadataPath); err != nil && !os.IsNotExist(err) {
			return CleanupResult{}, fmt.Errorf("remove orphaned metadata %s: %w", metadataPath, err)
		}
	}

	repaired, err := repairStateMarkers(options.StateDir, options.DataDir, options.BaseURL)
	if err != nil {
		// State is an optional host integration and must not invalidate cleanup.
		fmt.Fprintf(options.Output, "warning: could not repair state markers: %v\n", err)
	} else {
		result.RepairedStateMarkers = repaired
	}
	return result, nil
}

func acquireCleanupLock(dataDir string) (func(), error) {
	// The Compose stack bind-mounts the data subdirectories independently, so
	// lock a shared directory rather than the container-local /data mountpoint.
	directory, err := os.Open(filepath.Join(dataDir, "metadata"))
	if err != nil {
		return nil, fmt.Errorf("open metadata directory for cleanup lock: %w", err)
	}
	if err := syscall.Flock(int(directory.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = directory.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, errors.New("cleanup is already running")
		}
		return nil, fmt.Errorf("acquire cleanup lock: %w", err)
	}
	return func() {
		_ = syscall.Flock(int(directory.Fd()), syscall.LOCK_UN)
		_ = directory.Close()
	}, nil
}

func buildCleanupPlan(options CleanupOptions) (cleanupPlan, error) {
	hostedDir := filepath.Join(options.DataDir, "hosted")
	metadataDir := filepath.Join(options.DataDir, "metadata")
	archiveDir := filepath.Join(options.DataDir, "archive")
	archiveToday := filepath.Join(archiveDir, options.Now.Format("2006-01-02"))

	rootMetadata, err := readMetadataFiles(metadataDir)
	if err != nil {
		return cleanupPlan{}, err
	}
	metadataByFilename := make(map[string][]metadataFile)
	preserved := make(map[string]bool)
	for _, record := range rootMetadata {
		metadataByFilename[record.Metadata.Filename] = append(metadataByFilename[record.Metadata.Filename], record)
		preserved[record.Metadata.Filename] = preserved[record.Metadata.Filename] || record.Metadata.Preserve
	}

	archiveAssets, archiveDeletes, err := scanArchives(archiveDir, options)
	if err != nil {
		return cleanupPlan{}, err
	}
	hosted, err := readHostedFiles(hostedDir)
	if err != nil {
		return cleanupPlan{}, err
	}

	plan := cleanupPlan{
		ArchiveToday:    archiveToday,
		ArchiveDeletes:  archiveDeletes,
		RemainingHosted: make(map[string]hostedFile, len(hosted)),
	}
	hostedCutoff := options.Now.Add(-time.Duration(options.HostedRetentionDays) * 24 * time.Hour)
	targets := make(map[string]string)
	scheduledMetadata := make(map[string]bool)

	for _, file := range hosted {
		if !file.ModTime.Before(hostedCutoff) || preserved[file.Name] {
			plan.RemainingHosted[file.Name] = file
			continue
		}

		destination := filepath.Join(archiveToday, file.Name)
		if err := reserveCleanupTarget(targets, file.Path, destination); err != nil {
			return cleanupPlan{}, err
		}
		plan.FileMoves = append(plan.FileMoves, moveAction{Source: file.Path, Destination: destination})
		archiveAssets[file.Name] = true

		for _, record := range metadataByFilename[file.Name] {
			metadataDestination := filepath.Join(archiveToday, filepath.Base(record.Path))
			if err := reserveCleanupTarget(targets, record.Path, metadataDestination); err != nil {
				return cleanupPlan{}, err
			}
			plan.MetadataMoves = append(plan.MetadataMoves, moveAction{
				Source:      record.Path,
				Destination: metadataDestination,
			})
			scheduledMetadata[record.Path] = true
		}
	}

	for _, record := range rootMetadata {
		if scheduledMetadata[record.Path] {
			continue
		}
		if _, exists := plan.RemainingHosted[record.Metadata.Filename]; exists || archiveAssets[record.Metadata.Filename] {
			plan.RemainingMetadata = append(plan.RemainingMetadata, record)
			continue
		}
		plan.OrphanDeletes = append(plan.OrphanDeletes, record.Path)
	}

	sortMoveActions(plan.FileMoves)
	sortMoveActions(plan.MetadataMoves)
	sort.Strings(plan.ArchiveDeletes)
	sort.Strings(plan.OrphanDeletes)
	return plan, nil
}

func reserveCleanupTarget(targets map[string]string, source, destination string) error {
	if previous, exists := targets[destination]; exists {
		return fmt.Errorf("archive target collision: %s and %s both target %s", previous, source, destination)
	}
	if _, err := os.Lstat(destination); err == nil {
		return fmt.Errorf("archive target already exists: %s", destination)
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("inspect archive target %s: %w", destination, err)
	}
	targets[destination] = source
	return nil
}

func sortMoveActions(actions []moveAction) {
	sort.Slice(actions, func(i, j int) bool {
		return actions[i].Source < actions[j].Source
	})
}

func readHostedFiles(hostedDir string) ([]hostedFile, error) {
	entries, err := os.ReadDir(hostedDir)
	if err != nil {
		return nil, fmt.Errorf("read hosted directory: %w", err)
	}
	files := make([]hostedFile, 0, len(entries))
	for _, entry := range entries {
		if !entry.Type().IsRegular() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return nil, fmt.Errorf("inspect hosted file %s: %w", entry.Name(), err)
		}
		files = append(files, hostedFile{
			Path:    filepath.Join(hostedDir, entry.Name()),
			Name:    entry.Name(),
			ModTime: info.ModTime(),
		})
	}
	return files, nil
}

func readMetadataFiles(metadataDir string) ([]metadataFile, error) {
	entries, err := os.ReadDir(metadataDir)
	if err != nil {
		return nil, fmt.Errorf("read metadata directory: %w", err)
	}
	records := make([]metadataFile, 0, len(entries))
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		if !entry.Type().IsRegular() {
			return nil, fmt.Errorf("metadata path is not a regular file: %s", filepath.Join(metadataDir, entry.Name()))
		}
		path := filepath.Join(metadataDir, entry.Name())
		metadata, err := decodeMetadataFile(path)
		if err != nil {
			return nil, err
		}
		records = append(records, metadataFile{Path: path, Metadata: metadata})
	}
	return records, nil
}

func decodeMetadataFile(path string) (ScreenshotMetadata, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return ScreenshotMetadata{}, fmt.Errorf("read metadata %s: %w", path, err)
	}
	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()
	var metadata ScreenshotMetadata
	if err := decoder.Decode(&metadata); err != nil {
		return ScreenshotMetadata{}, fmt.Errorf("parse metadata %s: %w", path, err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			err = errors.New("multiple JSON values")
		}
		return ScreenshotMetadata{}, fmt.Errorf("parse metadata %s: %w", path, err)
	}
	if metadata.Filename == "" || filepath.Base(metadata.Filename) != metadata.Filename || metadata.Filename == "." {
		return ScreenshotMetadata{}, fmt.Errorf("parse metadata %s: invalid filename %q", path, metadata.Filename)
	}
	return metadata, nil
}

func scanArchives(archiveDir string, options CleanupOptions) (map[string]bool, []string, error) {
	assets := make(map[string]bool)
	entries, err := os.ReadDir(archiveDir)
	if os.IsNotExist(err) {
		return assets, nil, nil
	}
	if err != nil {
		return nil, nil, fmt.Errorf("read archive directory: %w", err)
	}

	cutoff := time.Date(options.Now.Year(), options.Now.Month(), options.Now.Day(), 0, 0, 0, 0, options.Now.Location()).
		AddDate(0, 0, -options.ArchiveRetentionDays)
	var deletes []string
	for _, entry := range entries {
		if !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		dirPath := filepath.Join(archiveDir, entry.Name())
		archiveDate, dateErr := time.ParseInLocation("2006-01-02", entry.Name(), options.Now.Location())
		validDate := dateErr == nil && archiveDate.Format("2006-01-02") == entry.Name()
		willDelete := validDate && archiveDate.Before(cutoff)

		children, err := os.ReadDir(dirPath)
		if err != nil {
			return nil, nil, fmt.Errorf("read archive directory %s: %w", dirPath, err)
		}
		for _, child := range children {
			if validDate && strings.HasSuffix(child.Name(), ".json") {
				if !child.Type().IsRegular() {
					return nil, nil, fmt.Errorf("archived metadata path is not a regular file: %s", filepath.Join(dirPath, child.Name()))
				}
				if _, err := decodeMetadataFile(filepath.Join(dirPath, child.Name())); err != nil {
					return nil, nil, err
				}
			}
			if !willDelete && child.Type().IsRegular() && !strings.HasSuffix(child.Name(), ".json") {
				assets[child.Name()] = true
			}
		}
		if willDelete {
			deletes = append(deletes, dirPath)
		}
	}
	return assets, deletes, nil
}

func moveFileNoReplace(source, destination string) (retErr error) {
	sourceInfo, err := os.Stat(source)
	if err != nil {
		return err
	}
	if !sourceInfo.Mode().IsRegular() {
		return errors.New("source is not a regular file")
	}

	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, sourceInfo.Mode().Perm())
	if err != nil {
		return err
	}
	defer func() {
		_ = output.Close()
		if retErr != nil {
			_ = os.Remove(destination)
		}
	}()

	if _, err := io.Copy(output, input); err != nil {
		return err
	}
	if err := output.Sync(); err != nil {
		return err
	}
	if err := output.Close(); err != nil {
		return err
	}
	if err := os.Chtimes(destination, sourceInfo.ModTime(), sourceInfo.ModTime()); err != nil {
		return err
	}
	if err := os.Remove(source); err != nil {
		return err
	}
	return nil
}

func rollbackMoves(completed []moveAction, output io.Writer) {
	for index := len(completed) - 1; index >= 0; index-- {
		action := completed[index]
		if err := moveFileNoReplace(action.Destination, action.Source); err != nil {
			fmt.Fprintf(output, "warning: rollback failed for %s: %v\n", action.Source, err)
		}
	}
}

func printCleanupPlan(output io.Writer, plan cleanupPlan) {
	for _, action := range plan.FileMoves {
		fmt.Fprintf(output, "would archive file: %s -> %s\n", action.Source, action.Destination)
	}
	for _, action := range plan.MetadataMoves {
		fmt.Fprintf(output, "would archive metadata: %s -> %s\n", action.Source, action.Destination)
	}
	for _, path := range plan.ArchiveDeletes {
		fmt.Fprintf(output, "would delete archive: %s\n", path)
	}
	for _, path := range plan.OrphanDeletes {
		fmt.Fprintf(output, "would delete orphaned metadata: %s\n", path)
	}
}

func stateMarkersNeedRepair(stateDir string, remaining map[string]hostedFile) bool {
	last, lastErr := readMarker(filepath.Join(stateDir, lastScreenshotMarker))
	latest, latestErr := readMarker(filepath.Join(stateDir, latestURLMarker))
	if len(remaining) == 0 {
		return lastErr == nil || latestErr == nil
	}
	if lastErr != nil || latestErr != nil {
		return true
	}
	if _, exists := remaining[last]; !exists {
		return true
	}
	return filenameFromURL(latest) != last
}

func repairStateMarkers(stateDir, dataDir, baseURL string) (bool, error) {
	hosted, err := readHostedFiles(filepath.Join(dataDir, "hosted"))
	if err != nil {
		return false, err
	}
	remaining := make(map[string]hostedFile, len(hosted))
	for _, file := range hosted {
		if isImageFile(file.Name) {
			remaining[file.Name] = file
		}
	}
	if len(remaining) == 0 {
		changed := false
		for _, marker := range []string{lastScreenshotMarker, latestURLMarker} {
			path := filepath.Join(stateDir, marker)
			if err := os.Remove(path); err == nil {
				changed = true
			} else if !os.IsNotExist(err) {
				return changed, err
			}
		}
		return changed, nil
	}

	last, _ := readMarker(filepath.Join(stateDir, lastScreenshotMarker))
	latest, _ := readMarker(filepath.Join(stateDir, latestURLMarker))
	chosen := ""
	if _, exists := remaining[last]; exists {
		chosen = last
	} else if fromURL := filenameFromURL(latest); remaining[fromURL].Name != "" {
		chosen = fromURL
	} else {
		files := make([]hostedFile, 0, len(remaining))
		for _, file := range remaining {
			files = append(files, file)
		}
		sort.Slice(files, func(i, j int) bool {
			if files[i].ModTime.Equal(files[j].ModTime) {
				return files[i].Name < files[j].Name
			}
			return files[i].ModTime.After(files[j].ModTime)
		})
		chosen = files[0].Name
	}

	desiredURL := strings.TrimRight(baseURL, "/") + "/" + chosen
	metadata, err := readMetadataFiles(filepath.Join(dataDir, "metadata"))
	if err != nil {
		return false, err
	}
	for _, record := range metadata {
		if record.Metadata.Filename == chosen && strings.TrimSpace(record.Metadata.URL) != "" {
			desiredURL = strings.TrimSpace(record.Metadata.URL)
			break
		}
	}
	if last == chosen && latest == desiredURL {
		return false, nil
	}
	if err := writeIngestionState(stateDir, chosen, desiredURL); err != nil {
		return false, err
	}
	return true, nil
}

func readMarker(path string) (string, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(contents))
	if value == "" {
		return "", errors.New("marker is empty")
	}
	return value, nil
}

func filenameFromURL(raw string) string {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return ""
	}
	name, err := url.PathUnescape(filepath.Base(parsed.Path))
	if err != nil || name == "." || filepath.Base(name) != name {
		return ""
	}
	return name
}
