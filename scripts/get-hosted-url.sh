#!/bin/bash
set -e

# Load environment variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Check if SSBNK_URL is set
if [ -z "$SSBNK_URL" ]; then
    echo "Error: SSBNK_URL not set in .env file" >&2
    exit 1
fi

# Get search query from arguments
QUERY="$*"

# Determine the data directory to search
# First try mounted volume
if mountpoint -q ./data 2>/dev/null && [ -d "./data/hosted" ]; then
    DATA_DIR="./data/hosted"
# Otherwise use docker volume directly
else
    # Get the volume mount path
    VOLUME_PATH=$(docker volume inspect ssbnk_data --format '{{ .Mountpoint }}' 2>/dev/null)
    if [ -z "$VOLUME_PATH" ]; then
        echo "Error: Docker volume 'ssbnk_data' not found and ./data not mounted" >&2
        echo "Run 'sudo mise mount' first or ensure ssbnk services are running" >&2
        exit 1
    fi
    DATA_DIR="$VOLUME_PATH/hosted"
    
    # Check if we can access it
    if ! sudo test -d "$DATA_DIR"; then
        echo "Error: Cannot access hosted directory at $DATA_DIR" >&2
        exit 1
    fi
fi

# Function to list files
list_files() {
    if [[ "$DATA_DIR" == "./data/hosted" ]]; then
        # Local mount, no sudo needed
        find "$DATA_DIR" -type f -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.gif" -o -name "*.webp" 2>/dev/null | \
            sed "s|$DATA_DIR/||" | sort -r
    else
        # Docker volume, needs sudo
        sudo find "$DATA_DIR" -type f -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.gif" -o -name "*.webp" 2>/dev/null | \
            sed "s|$DATA_DIR/||" | sort -r
    fi
}

# If query provided, use it as initial filter for fzf
if [ -n "$QUERY" ]; then
    SELECTED=$(list_files | fzf --filter="$QUERY" | head -n1)
else
    # Interactive mode
    SELECTED=$(list_files | fzf --prompt="Select hosted file: " --height=40% --reverse)
fi

# Check if a file was selected
if [ -z "$SELECTED" ]; then
    echo "No file selected or found" >&2
    exit 1
fi

# Output the full URL
echo "${SSBNK_URL}/hosted/${SELECTED}"