#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running with sudo
if [ "$EUID" -ne 0 ]; then 
    echo -e "${YELLOW}This script requires sudo privileges.${NC}"
    echo "Please run: sudo ./scripts/mount-volume.sh"
    exit 1
fi

# Get the volume mount path
VOLUME_PATH=$(docker volume inspect ssbnk_data --format '{{ .Mountpoint }}' 2>/dev/null)

if [ -z "$VOLUME_PATH" ]; then
    echo -e "${RED}Error: Docker volume 'ssbnk_data' not found${NC}"
    echo "Make sure the ssbnk services are running: docker compose up -d"
    exit 1
fi

# Create data directory if it doesn't exist
mkdir -p ./data

# Check if already mounted
if mountpoint -q ./data 2>/dev/null; then
    echo -e "${YELLOW}Directory ./data is already mounted${NC}"
    echo "Volume path: $VOLUME_PATH"
    exit 0
fi

# Mount the volume
if mount --bind "$VOLUME_PATH" ./data; then
    echo -e "${GREEN}Successfully mounted ssbnk_data volume to ./data${NC}"
    echo "Volume path: $VOLUME_PATH"
    echo ""
    echo "You can now access the volume data in ./data/"
    echo "To unmount, run: sudo ./scripts/umount-volume.sh"
else
    echo -e "${RED}Failed to mount volume${NC}"
    exit 1
fi