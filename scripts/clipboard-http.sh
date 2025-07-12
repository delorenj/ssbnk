#!/bin/bash

# HTTP Clipboard Service for ssbnk
# Listens on localhost:9999 for clipboard requests

echo "📸 ssbnk HTTP Clipboard Service"
echo "Listening on http://localhost:9999"

while true; do
    # Listen for HTTP requests
    response=$(echo -e "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK" | nc -l -p 9999 -q 1)
    
    # Extract the URL from POST body
    url=$(echo "$response" | tail -1)
    
    if [ -n "$url" ] && [[ "$url" == http* ]]; then
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
