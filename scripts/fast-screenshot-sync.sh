#!/bin/bash

# Fast Screenshot Sync for Bloodbank
# Watches for screenshots and immediately syncs them

WATCH_DIR="$HOME/ss"
SYNC_COMMAND="syncthing cli operations restart"

echo "🩸 Fast Screenshot Sync Started"
echo "Watching: $WATCH_DIR"

# Use inotify for instant file detection
inotifywait -m -e create,moved_to "$WATCH_DIR" --format '%w%f %e' |
while read file event; do
    # Check if it's an image file
    if [[ "$file" =~ \.(png|jpg|jpeg|gif|webp)$ ]]; then
        echo "📸 New screenshot detected: $(basename "$file")"
        
        # Force immediate Syncthing scan
        curl -s -X POST -H "X-API-Key: CAGmzQmefZA5ykZTv5EhK45KfXw3zq6f" \
          "http://localhost:8384/rest/db/scan?folder=ss" > /dev/null
        
        echo "🔄 Triggered immediate sync"
        
        # Optional: Wait a moment and check sync status
        sleep 2
        sync_status=$(curl -s -H "X-API-Key: CAGmzQmefZA5ykZTv5EhK45KfXw3zq6f" \
          "http://localhost:8384/rest/db/status?folder=ss" | jq -r '.state')
        echo "📊 Sync status: $sync_status"
    fi
done
