#!/bin/bash
#
# Remote Screenshot Uploader for ssbnk
# Run this on remote machines. Watches for new screenshots and POSTs them
# directly to the ssbnk host, which treats them like local screenshots.
#
# Usage:
#   SSBNK_HOST=https://ss.delo.sh SSBNK_UPLOAD_KEY=your-key ./remote-screenshot-upload.sh
#
# Or (preferred) set values in ~/.config/ssbnk/remote.env — it is sourced
# automatically if present.
#
# Supports multiple watch directories via SSBNK_SCREENSHOT_DIR (colon-separated).
# Linux uses inotifywait (inotify-tools); macOS uses fswatch (brew install fswatch).
#
# Install as a service with scripts/install-remote-client.sh from the ssbnk repo.

set -euo pipefail

# Source config file if present (does not override already-set env vars)
REMOTE_ENV="${SSBNK_REMOTE_ENV:-$HOME/.config/ssbnk/remote.env}"
if [ -f "$REMOTE_ENV" ]; then
    # shellcheck disable=SC1090
    . "$REMOTE_ENV"
fi

# Configuration
SSBNK_HOST="${SSBNK_HOST:?Set SSBNK_HOST (e.g. https://ss.delo.sh)}"
SSBNK_UPLOAD_KEY="${SSBNK_UPLOAD_KEY:?Set SSBNK_UPLOAD_KEY}"

# Platform detection: watcher command, clipboard, default screenshot dir
OS="$(uname -s)"
case "$OS" in
    Linux)
        WATCHER_CMD="inotifywait"
        DEFAULT_SCREENSHOT_DIR="$HOME/Screenshots"
        ;;
    Darwin)
        WATCHER_CMD="fswatch"
        DEFAULT_SCREENSHOT_DIR="$HOME/Desktop"
        # Homebrew isn't in launchd's default PATH
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        ;;
    *)
        echo "Unsupported OS: $OS (need Linux or macOS)"
        exit 1
        ;;
esac

WATCH_DIRS_RAW="${SSBNK_SCREENSHOT_DIR:-$DEFAULT_SCREENSHOT_DIR}"
UPLOAD_RETRIES="${SSBNK_UPLOAD_RETRIES:-3}"

# Validate dependencies
for cmd in "$WATCHER_CMD" curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Missing dependency: $cmd"
        if [ "$cmd" = "inotifywait" ]; then
            echo "  Install with: sudo apt install inotify-tools  (or your distro's equivalent)"
        elif [ "$cmd" = "fswatch" ]; then
            echo "  Install with: brew install fswatch"
        fi
        exit 1
    fi
done

# Parse colon-separated watch dirs, filter to existing ones
IFS=':' read -ra CANDIDATE_DIRS <<< "$WATCH_DIRS_RAW"
WATCH_DIRS=()
for dir in "${CANDIDATE_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        WATCH_DIRS+=("$dir")
    else
        echo "Skipping non-existent directory: $dir"
    fi
done

if [ ${#WATCH_DIRS[@]} -eq 0 ]; then
    echo "No valid screenshot directories found."
    exit 1
fi

echo "ssbnk remote uploader ($OS, $WATCHER_CMD)"
echo "  Host: $SSBNK_HOST"
for dir in "${WATCH_DIRS[@]}"; do
    echo "  Watching: $dir (recursive)"
done
echo ""

# Portable helpers (macOS ships bash 3.2 + BSD coreutils)
file_hash() {
    if command -v md5sum &>/dev/null; then
        printf '%s' "$1" | md5sum | cut -d' ' -f1
    else
        printf '%s' "$1" | md5
    fi
}

# Wait until the file size stops changing (screenshots can be written slowly)
wait_for_stable_file() {
    local file="$1" last_size=0 size=0 i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -f "$file" ] || return 1
        size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0)
        if [ "$size" -gt 0 ] && [ "$size" = "$last_size" ]; then
            return 0
        fi
        last_size=$size
        sleep 0.3
    done
    [ "$size" -gt 0 ]
}

copy_to_clipboard() {
    local text="$1"
    if command -v wl-copy &>/dev/null; then
        printf '%s' "$text" | wl-copy
    elif command -v pbcopy &>/dev/null; then
        printf '%s' "$text" | pbcopy
    elif command -v xclip &>/dev/null; then
        printf '%s' "$text" | xclip -selection clipboard
    fi
}

upload_screenshot() {
    local file="$1"
    local filename
    filename=$(basename "$file")

    # Dedupe across concurrent events: atomic lock dir per unique file path
    local lock="/tmp/ssbnk-upload.$(file_hash "$file")"
    if ! mkdir "$lock" 2>/dev/null; then
        return 0  # another event for this file is already being handled
    fi

    if ! wait_for_stable_file "$file"; then
        echo "Skipping (gone or empty): $filename"
        rmdir "$lock" 2>/dev/null || true
        return 0
    fi

    echo "Uploading: $filename"

    local attempt=1 response http_code body url rc=1
    while [ "$attempt" -le "$UPLOAD_RETRIES" ]; do
        response=$(curl -sS -w "\n%{http_code}" \
            -X POST \
            -H "X-Upload-Key: $SSBNK_UPLOAD_KEY" \
            -F "file=@$file" \
            "$SSBNK_HOST/upload" 2>&1) || true

        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | sed '$d')

        if [ "$http_code" = "200" ]; then
            url=$(echo "$body" | grep -o '"url":"[^"]*"' | cut -d'"' -f4)
            echo "  OK: $url"

            copy_to_clipboard "$url"

            # Save the local file path for paste-image
            mkdir -p /tmp/ssbnk
            echo "$file" > /tmp/ssbnk/last-screenshot
            rc=0
            break
        fi

        echo "  Attempt $attempt/$UPLOAD_RETRIES failed ($http_code): $body"
        attempt=$((attempt + 1))
        [ "$attempt" -le "$UPLOAD_RETRIES" ] && sleep 2
    done

    [ "$rc" -ne 0 ] && echo "  FAILED after $UPLOAD_RETRIES attempts: $filename"
    rmdir "$lock" 2>/dev/null || true
    return "$rc"
}

is_image_file() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        *.png|*.jpg|*.jpeg|*.gif|*.webp) return 0 ;;
        *) return 1 ;;
    esac
}

# Watch for new screenshots and upload as they appear
if [ "$WATCHER_CMD" = "inotifywait" ]; then
    inotifywait -m -r -e create,moved_to "${WATCH_DIRS[@]}" --format '%w%f' |
    while read -r file; do
        if is_image_file "$file"; then
            upload_screenshot "$file" &
        fi
    done
else
    # fswatch: recursive by default; latency coalesces duplicate events
    fswatch -0 -r --latency=0.5 --event Created --event MovedTo "${WATCH_DIRS[@]}" |
    while IFS= read -r -d '' file; do
        if [ -f "$file" ] && is_image_file "$file"; then
            upload_screenshot "$file" &
        fi
    done
fi
