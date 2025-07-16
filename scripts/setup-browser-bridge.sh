#!/bin/bash

# Setup browser bridge for ssbnk
# This creates a named pipe that the container can write to
# for opening URLs in the host's browser

PIPE_PATH="/tmp/ssbnk-browser"

echo "Setting up ssbnk browser bridge..."

# Remove existing pipe if it exists
if [ -p "$PIPE_PATH" ]; then
    rm "$PIPE_PATH"
fi

# Create the named pipe
mkfifo "$PIPE_PATH"
chmod 666 "$PIPE_PATH"

echo "Browser bridge created at $PIPE_PATH"
echo "Starting listener..."

# Listen for URLs and open them
while true; do
    if read url < "$PIPE_PATH"; then
        echo "Opening: $url"
        xdg-open "$url" 2>/dev/null || echo "Failed to open URL"
    fi
done