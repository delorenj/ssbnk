#!/bin/bash

# Local Screenshot Watcher for Remote ssbnk
# Run this on your LOCAL machine to watch for screenshots and immediately sync them

# Configuration - UPDATE THESE FOR YOUR LOCAL MACHINE
LOCAL_SCREENSHOT_DIR="$HOME/Screenshots"  # Adjust to your local screenshot directory
LOCAL_API_KEY="YOUR_LOCAL_API_KEY"        # Get from your local Syncthing
REMOTE_HOST="your-remote-host"
REMOTE_API_KEY="YOUR_REMOTE_API_KEY"

echo "📸 Local Screenshot Watcher for Remote ssbnk"
echo "Watching: $LOCAL_SCREENSHOT_DIR"
echo "Remote: $REMOTE_HOST"
echo ""

# Check if inotify-tools is installed
if ! command -v inotifywait >/dev/null 2>&1; then
    echo "❌ inotify-tools not installed!"
    echo "Install with: sudo apt install inotify-tools"
    exit 1
fi

# Check if local screenshot directory exists
if [ ! -d "$LOCAL_SCREENSHOT_DIR" ]; then
    echo "❌ Screenshot directory not found: $LOCAL_SCREENSHOT_DIR"
    echo "Please update LOCAL_SCREENSHOT_DIR in this script"
    exit 1
fi

# Function to sync screenshot
sync_screenshot() {
    local file="$1"
    local filename=$(basename "$file")
    
    echo "📸 New screenshot detected: $filename"
    
    # Step 1: Trigger local Syncthing scan
    echo "  📤 Triggering local sync..."
    curl -s -X POST -H "X-API-Key: $LOCAL_API_KEY" \
      "http://localhost:8384/rest/db/scan?folder=ss" > /dev/null
    
    # Step 2: Wait a moment for local sync to process
    sleep 2
    
    # Step 3: Trigger remote Syncthing scan
    echo "  📥 Triggering remote sync..."
    curl -s -X POST -H "X-API-Key: $REMOTE_API_KEY" \
      "http://$REMOTE_HOST:8384/rest/db/scan?folder=ss" > /dev/null
    
    # Step 4: Check sync status
    echo "  📊 Checking sync status..."
    local completion=$(curl -s -H "X-API-Key: $REMOTE_API_KEY" \
      "http://$REMOTE_HOST:8384/rest/db/completion?folder=ss" | jq -r '.completion')
    
    echo "  ✅ Sync triggered - Remote completion: ${completion}%"
    
    # Step 5: Notify when file should be available
    echo "  📸 File should be available for ssbnk processing in ~5-10 seconds"
    echo ""
}

# Watch for new screenshots
echo "👀 Watching for new screenshots..."
echo "Press Ctrl+C to stop"
echo ""

inotifywait -m -e create,moved_to "$LOCAL_SCREENSHOT_DIR" --format '%w%f %e' |
while read file event; do
    # Check if it's an image file
    if [[ "$file" =~ \.(png|jpg|jpeg|gif|webp)$ ]]; then
        sync_screenshot "$file"
    fi
done
