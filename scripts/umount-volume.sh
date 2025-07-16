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
    echo "Please run: sudo ./scripts/umount-volume.sh"
    exit 1
fi

# Check if mounted
if ! mountpoint -q ./data 2>/dev/null; then
    echo -e "${YELLOW}Directory ./data is not mounted${NC}"
    exit 0
fi

# Unmount the volume
if umount ./data; then
    echo -e "${GREEN}Successfully unmounted ssbnk_data volume from ./data${NC}"
else
    echo -e "${RED}Failed to unmount volume${NC}"
    echo "Make sure no processes are using files in ./data/"
    exit 1
fi