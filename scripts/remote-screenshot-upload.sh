#!/bin/bash
#
# Remote Screenshot Uploader for ssbnk
# Run this on remote machines instead of Syncthing.
# Watches for new screenshots and POSTs them directly to the host.
#
# Usage:
#   SSBNK_HOST=https://ss.delo.sh SSBNK_UPLOAD_KEY=your-key ./remote-screenshot-upload.sh
#
# Or set in ~/.config/ssbnk/remote.env and source it.
#
# Supports multiple watch directories via SSBNK_SCREENSHOT_DIR (colon-separated)
# and auto-watches subdirectories recursively.

set -euo pipefail

# Configuration
SSBNK_HOST="${SSBNK_HOST:?Set SSBNK_HOST (e.g. https://ss.delo.sh)}"
SSBNK_UPLOAD_KEY="${SSBNK_UPLOAD_KEY:?Set SSBNK_UPLOAD_KEY}"
WATCH_DIRS_RAW="${SSBNK_SCREENSHOT_DIR:-$HOME/Screenshots}"

# Validate dependencies
for cmd in inotifywait curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Missing dependency: $cmd"
        echo "  Install with: sudo apt install inotify-tools curl"
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

echo "ssbnk remote uploader"
echo "  Host: $SSBNK_HOST"
for dir in "${WATCH_DIRS[@]}"; do
    echo "  Watching: $dir (recursive)"
done
echo ""

upload_screenshot() {
    local file="$1"
    local filename
    filename=$(basename "$file")

    # Brief pause to ensure file is fully written
    sleep 0.2

    echo "Uploading: $filename"

    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "X-Upload-Key: $SSBNK_UPLOAD_KEY" \
        -F "file=@$file" \
        "$SSBNK_HOST/upload" 2>&1)

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)

    if [ "$http_code" = "200" ]; then
        url=$(echo "$body" | grep -o '"url":"[^"]*"' | cut -d'"' -f4)
        echo "  OK: $url"

        # Copy URL to local clipboard
        if command -v wl-copy &>/dev/null; then
            echo -n "$url" | wl-copy
        elif command -v xclip &>/dev/null; then
            echo -n "$url" | xclip -selection clipboard
        fi

        # Also save the local file path for paste-image
        mkdir -p /tmp/ssbnk
        echo "$file" > /tmp/ssbnk/last-screenshot
    else
        echo "  FAILED ($http_code): $body"
    fi
}

# Watch for new screenshots (-r for recursive subdirectories)
inotifywait -m -r -e create,moved_to "${WATCH_DIRS[@]}" --format '%w%f' |
while read -r file; do
    if [[ "$file" =~ \.(png|jpg|jpeg|gif|webp)$ ]]; then
        upload_screenshot "$file" &
    fi
done
