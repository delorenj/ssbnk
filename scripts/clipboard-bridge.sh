#!/bin/bash

# ssbnk Clipboard Bridge
# This script runs on the host and provides clipboard access to the container

FIFO_PATH="/tmp/ssbnk-clipboard"

# Create named pipe if it doesn't exist
if [ ! -p "$FIFO_PATH" ]; then
    mkfifo "$FIFO_PATH"
    echo "Created clipboard bridge at $FIFO_PATH"
fi

echo "📸 ssbnk Clipboard Bridge Started"
echo "Listening for clipboard requests..."

# Listen for clipboard requests
while true; do
    if read -r url < "$FIFO_PATH"; then
        echo "📋 Copying to clipboard: $url"
        
        # Detect display server and copy appropriately
        if [ -n "$WAYLAND_DISPLAY" ] || [ "$XDG_SESSION_TYPE" = "wayland" ]; then
            echo "$url" | wl-copy
            echo "✅ Copied via wl-copy (Wayland)"
        else
            echo "$url" | xclip -selection clipboard
            echo "✅ Copied via xclip (X11)"
        fi
    fi
done
