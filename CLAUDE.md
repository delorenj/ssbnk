# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ssbnk (ScreenShot Bank) is a containerized screenshot and screencast hosting service that automatically detects, processes, and hosts screenshots with URL clipboard integration. It also converts video screencasts to looping GIFs. Built with Go for the file watcher, Nginx for serving, FFmpeg for video conversion, and integrated with Traefik for reverse proxy.

## Common Development Commands

### Building and Running

```bash
# Start the service
docker compose up -d

# Build and restart the watcher service
docker compose build ssbnk-watcher && docker compose up -d ssbnk-watcher

# View logs for all services
docker compose logs -f

# View specific service logs
docker compose logs -f ssbnk-watcher
docker compose logs -f ssbnk-cleanup
```

### Testing and Debugging

```bash
# Test screenshot processing manually
./scripts/instant-screenshot.sh

# Check display server configuration
./scripts/detect-display-server.sh

# Force sync a specific screenshot
./scripts/force-screenshot-sync.sh /path/to/screenshot.png

# Test cleanup process manually
docker exec ssbnk-cleanup /cleanup.sh

# Check clipboard functionality
docker compose exec ssbnk-watcher which wl-copy  # Wayland
docker compose exec ssbnk-watcher which xclip    # X11
```

### Go Development

```bash
# Run watcher locally (outside container)
cd watcher
go mod download
go run main.go

# Run tests
cd watcher
go test ./...

# Build binary
cd watcher
go build -o ssbnk-watcher
```

## Architecture & Key Components

### Service Structure

1. **ssbnk-watcher** (Go service):

   - File watching with fsnotify for both screenshots and videos
   - Screenshot processing and metadata generation
   - Video to GIF conversion using FFmpeg (max 10 seconds, optimized palette)
   - Multi-method clipboard integration (direct, FIFO bridge, HTTP service)
   - Display server agnostic (X11/Wayland auto-detection)
   - Watches two directories: screenshots and ~/Videos/Screencasts

2. **ssbnk-web** (Nginx):

   - Serves hosted screenshots at `${SSBNK_DOMAIN}/hosted/`
   - Optimized caching headers
   - Connected to Traefik proxy network

3. **ssbnk-cleanup** (Alpine cron):
   - Daily cleanup at 2 AM
   - Archives old screenshots based on retention policy
   - Manages metadata and orphaned files
   - Preserves marked screenshots

### Key Code Paths

- `watcher/main.go`: Core file watching and processing logic
- `scripts/cleanup.sh`: Archive and cleanup implementation
- `compose.yml`: Service orchestration and configuration
- `nginx/default.conf`: Web server routing configuration

### Display Server Integration

The watcher supports both X11 and Wayland with automatic detection:

- Primary method: Direct clipboard access (xclip/wl-copy)
- Fallback 1: FIFO bridge at `/tmp/ssbnk-clipboard`
- Fallback 2: HTTP clipboard service on port 9999

Detection order:

1. Check `WAYLAND_DISPLAY` environment variable
2. Check `XDG_SESSION_TYPE` for "wayland"
3. Test wl-copy availability and connectivity
4. Default to X11/xclip

### Data Flow

Screenshots:

1. User saves screenshot to `${SSBNK_IMAGE_DIR}`
2. Watcher detects new file via fsnotify
3. File is moved to `/data/hosted/` with timestamp naming
4. Metadata JSON created in `/data/metadata/`
5. URL copied to clipboard
6. Original file removed from watch directory
7. Daily cleanup archives old files to `/data/archive/YYYY-MM-DD/`

Videos:

1. User saves video to `~/Videos/Screencasts`
2. Watcher detects new video file
3. FFmpeg converts video to GIF (10 sec max, 640px width, optimized palette)
4. GIF is placed in screenshot watch directory
5. GIF processed as regular screenshot (hosted, URL copied)
6. Original video file removed

## Important Implementation Details

- File operations use copy+remove (not rename) for cross-volume compatibility
- Unique filename generation handles collisions with counter suffix
- Metadata includes preserve flag to prevent archival
- Clipboard integration has three fallback methods for reliability
- Archive cleanup removes directories older than retention period
- All timestamps use ISO format for consistent sorting
- Video conversion uses FFmpeg with optimized settings:
  - 10 second limit to keep GIF sizes reasonable
  - 640px width with proportional height
  - Palette generation for better color quality
  - 10 fps for smooth playback
- Supported video formats: MP4, AVI, MOV, MKV, WebM, FLV, WMV

## Environment Configuration

Required environment variables (from root `.env`):

- `SSBNK_URL`: Full HTTPS URL for hosted screenshots
- `SSBNK_DOMAIN`: Domain for Traefik routing
- `SSBNK_IMAGE_DIR`: Local directory to watch for screenshots
- `SSBNK_RETENTION_DAYS`: Days to retain screenshots (default: 30)
- Display variables: `DISPLAY`, `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`

## DeLoContainers Integration

This service follows DeLoContainers standards:

- Service at `stacks/utils/ssbnk/`
- Traefik routing via Docker labels
- Connected to shared `proxy` network
- Environment from root `.env` file
- No version key in compose.yml

