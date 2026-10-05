package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
)

const uploadVersion = 2
const receiptReservationBytes = int64(8192)

type UploadLimits struct {
	ImageBytes               int64  `json:"image_bytes"`
	VideoBytes               int64  `json:"video_bytes"`
	ReservationBytes         int64  `json:"reservation_bytes"`
	Slots                    int    `json:"slots"`
	Receivers                int    `json:"receivers"`
	ChunkBytes               int64  `json:"chunk_bytes"`
	MinimumChunkBytes        int64  `json:"minimum_chunk_bytes"`
	DefaultChunkBytes        int64  `json:"default_chunk_bytes"`
	OutputBytes              int64  `json:"output_bytes"`
	OverheadBytes            int64  `json:"overhead_bytes"`
	FreeFloorBytes           int64  `json:"free_floor_bytes"`
	ReceiptBytes             int64  `json:"receipt_bytes"`
	Dimension                int    `json:"dimension"`
	Pixels                   int64  `json:"pixels"`
	ResultHeight             int    `json:"result_height"`
	ResultPixels             int64  `json:"result_pixels"`
	ProbeMemoryBytes         uint64 `json:"probe_memory_bytes"`
	ConversionMemoryBytes    uint64 `json:"conversion_memory_bytes"`
	VerificationSeconds      int64  `json:"verification_seconds"`
	ConversionSeconds        int64  `json:"conversion_seconds"`
	Attempts                 int    `json:"attempts"`
	ReceivingIdleSeconds     int64  `json:"receiving_idle_seconds"`
	ReceivingAbsoluteSeconds int64  `json:"receiving_absolute_seconds"`
	FailureSeconds           int64  `json:"failure_seconds"`
}

func defaultUploadLimits() UploadLimits {
	return UploadLimits{
		ImageBytes: 50 << 20, VideoBytes: 1 << 30, ReservationBytes: 4 << 30,
		Slots: 8, Receivers: 2, ChunkBytes: 4 << 20, MinimumChunkBytes: 64 << 10, DefaultChunkBytes: 1 << 20,
		OutputBytes: 128 << 20, OverheadBytes: 32 << 20, FreeFloorBytes: 512 << 20, ReceiptBytes: 64 << 20,
		Dimension: 8192, Pixels: 33177600, ResultHeight: 2560, ResultPixels: 1638400,
		ProbeMemoryBytes: 512 << 20, ConversionMemoryBytes: 1 << 30,
		VerificationSeconds: 180, ConversionSeconds: 300, Attempts: 3,
		ReceivingIdleSeconds: 86400, ReceivingAbsoluteSeconds: 604800, FailureSeconds: 604800,
	}
}

func uploadLimitsFromEnv() (UploadLimits, error) {
	limits := defaultUploadLimits()
	values := map[string]*int64{
		"IMAGE_BYTES": &limits.ImageBytes, "VIDEO_BYTES": &limits.VideoBytes,
		"RESERVATION_BYTES": &limits.ReservationBytes, "CHUNK_BYTES": &limits.ChunkBytes,
		"OUTPUT_BYTES": &limits.OutputBytes, "OVERHEAD_BYTES": &limits.OverheadBytes,
		"FREE_FLOOR_BYTES": &limits.FreeFloorBytes, "RECEIPT_BYTES": &limits.ReceiptBytes,
		"PIXELS": &limits.Pixels, "RESULT_PIXELS": &limits.ResultPixels,
		"VERIFICATION_SECONDS": &limits.VerificationSeconds, "CONVERSION_SECONDS": &limits.ConversionSeconds,
		"RECEIVING_IDLE_SECONDS": &limits.ReceivingIdleSeconds, "RECEIVING_ABSOLUTE_SECONDS": &limits.ReceivingAbsoluteSeconds,
		"FAILURE_SECONDS": &limits.FailureSeconds,
	}
	for name, destination := range values {
		raw := os.Getenv("SSBNK_UPLOAD_" + name)
		if raw == "" {
			continue
		}
		value, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || value <= 0 || value > 1<<40 {
			return limits, fmt.Errorf("SSBNK_UPLOAD_%s must be a positive integer <= 1 TiB", name)
		}
		*destination = value
	}
	integers := map[string]*int{"SLOTS": &limits.Slots, "RECEIVERS": &limits.Receivers, "DIMENSION": &limits.Dimension, "RESULT_HEIGHT": &limits.ResultHeight, "ATTEMPTS": &limits.Attempts}
	for name, destination := range integers {
		raw := os.Getenv("SSBNK_UPLOAD_" + name)
		if raw == "" {
			continue
		}
		value, err := strconv.Atoi(raw)
		if err != nil || value <= 0 || value > 8192 {
			return limits, fmt.Errorf("SSBNK_UPLOAD_%s must be between 1 and 8192", name)
		}
		*destination = value
	}
	for name, destination := range map[string]*uint64{"PROBE_MEMORY_BYTES": &limits.ProbeMemoryBytes, "CONVERSION_MEMORY_BYTES": &limits.ConversionMemoryBytes} {
		raw := os.Getenv("SSBNK_UPLOAD_" + name)
		if raw == "" {
			continue
		}
		value, err := strconv.ParseUint(raw, 10, 64)
		if err != nil || value < 64<<20 || value > 1<<40 {
			return limits, fmt.Errorf("SSBNK_UPLOAD_%s must be between 64 MiB and 1 TiB", name)
		}
		*destination = value
	}
	if limits.ChunkBytes < limits.MinimumChunkBytes || limits.ChunkBytes > 4<<20 || limits.ReceiptBytes < receiptReservationBytes || limits.OverheadBytes < 32<<20 || limits.Receivers > limits.Slots || limits.Attempts > 3 || limits.VerificationSeconds > 86400 || limits.ConversionSeconds > 86400 {
		return limits, errors.New("invalid upload limit relationships")
	}
	if limits.DefaultChunkBytes > limits.ChunkBytes {
		limits.DefaultChunkBytes = limits.ChunkBytes
	}
	return limits, nil
}

type UploadDescriptor struct {
	Version      int       `json:"version"`
	OriginalName string    `json:"original_name"`
	Kind         string    `json:"kind"`
	Size         int64     `json:"size"`
	SHA256       string    `json:"sha256"`
	CaptureTime  time.Time `json:"capture_time"`
	Profile      string    `json:"profile"`
}

func (d UploadDescriptor) canonical(limits UploadLimits) (UploadDescriptor, error) {
	if d.Version != uploadVersion {
		return d, errors.New("unsupported protocol version")
	}
	if !utf8.ValidString(d.OriginalName) || d.OriginalName == "" || len(d.OriginalName) > 255 || strings.ContainsAny(d.OriginalName, "/\\\x00\r\n") || filepath.Base(d.OriginalName) != d.OriginalName || d.OriginalName == "." || d.OriginalName == ".." {
		return d, errors.New("original_name must be a bounded basename")
	}
	if d.Kind != "image" && d.Kind != "video" {
		return d, errors.New("unsupported input kind")
	}
	if (d.Kind == "image" && d.Profile != "original") || (d.Kind == "video" && d.Profile != "gif-30s-10fps-640") {
		return d, errors.New("unsupported media profile")
	}
	maximum := limits.ImageBytes
	if d.Kind == "video" {
		maximum = limits.VideoBytes
	}
	if d.Size <= 0 || d.Size > maximum {
		return d, errors.New("input size exceeds media limit")
	}
	if !validSHA256(d.SHA256) {
		return d, errors.New("invalid SHA-256")
	}
	if d.CaptureTime.IsZero() {
		return d, errors.New("capture_time is required")
	}
	d.SHA256 = strings.ToLower(d.SHA256)
	d.CaptureTime = d.CaptureTime.UTC()
	return d, nil
}

func validSHA256(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 32
}

func canonicalUploadID(value string) (string, error) {
	id, err := uuid.Parse(value)
	if err != nil || id == uuid.Nil || id.String() != value {
		return "", errors.New("UUID must be canonical and nonzero")
	}
	return id.String(), nil
}

type UploadFailure struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}

type UploadResult struct {
	URL          string `json:"url"`
	Filename     string `json:"filename"`
	MetadataID   string `json:"metadata_id"`
	MediaType    string `json:"media_type"`
	Size         int64  `json:"size"`
	SHA256       string `json:"sha256"`
	Availability string `json:"availability"`
}

type UploadReceipt struct {
	UUID string `json:"uuid"`
	UploadDescriptor
	Offset         int64          `json:"offset"`
	State          string         `json:"state"`
	Attempt        int            `json:"attempt"`
	CreatedAt      time.Time      `json:"created_at"`
	ProgressAt     time.Time      `json:"progress_at"`
	AcceptedAt     *time.Time     `json:"accepted_at,omitempty"`
	FirstFailureAt *time.Time     `json:"first_failure_at,omitempty"`
	ExpiresAt      *time.Time     `json:"expires_at,omitempty"`
	Error          *UploadFailure `json:"error,omitempty"`
	Result         *UploadResult  `json:"result,omitempty"`
}

type committedChunk struct {
	Offset int64  `json:"offset"`
	Length int64  `json:"length"`
	SHA256 string `json:"sha256"`
}

type preparedUpload struct {
	Metadata ScreenshotMetadata `json:"metadata"`
	Result   UploadResult       `json:"result"`
}

type uploadJournal struct {
	JournalVersion int             `json:"journal_version"`
	Receipt        UploadReceipt   `json:"receipt"`
	LastChunk      *committedChunk `json:"last_chunk,omitempty"`
	Prepared       *preparedUpload `json:"prepared,omitempty"`
	Reservation    int64           `json:"reservation"`
	Intake         *intakeIdentity `json:"intake,omitempty"`
}

func decodeBoundedJSON(reader io.Reader, limit int64, value any) error {
	data, err := io.ReadAll(io.LimitReader(reader, limit+1))
	if err != nil {
		return err
	}
	if int64(len(data)) > limit {
		return errors.New("JSON body exceeds limit")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	if err := decoder.Decode(new(any)); !errors.Is(err, io.EOF) {
		return errors.New("trailing JSON value")
	}
	return nil
}
