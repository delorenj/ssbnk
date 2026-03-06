#!/bin/sh

# Generate missing metadata for existing images
# This script creates JSON metadata files for images that don't have them

HOSTED_DIR="/data/hosted"
METADATA_DIR="/data/metadata"
BASE_URL="https://ss.delo.sh"

echo "Starting metadata generation for missing files..."

# Ensure metadata directory exists
mkdir -p "$METADATA_DIR"

# Count existing files
TOTAL_IMAGES=$(find "$HOSTED_DIR" -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.gif" -o -name "*.webp" \) | wc -l)
EXISTING_METADATA=$(find "$METADATA_DIR" -name "*.json" | wc -l)

echo "Found $TOTAL_IMAGES image files and $EXISTING_METADATA existing metadata files"

# Generate metadata for each image file that doesn't have it
GENERATED=0

for image_file in "$HOSTED_DIR"/*.png "$HOSTED_DIR"/*.jpg "$HOSTED_DIR"/*.jpeg "$HOSTED_DIR"/*.gif "$HOSTED_DIR"/*.webp; do
    # Skip if file doesn't exist (handles glob expansion when no files match)
    [ -f "$image_file" ] || continue
    
    filename=$(basename "$image_file")
    
    # Check if metadata already exists for this file
    metadata_exists=false
    for metadata_file in "$METADATA_DIR"/*.json; do
        [ -f "$metadata_file" ] || continue
        if grep -q "\"filename\".*:.*\"$filename\"" "$metadata_file" 2>/dev/null; then
            metadata_exists=true
            break
        fi
    done
    
    if [ "$metadata_exists" = true ]; then
        echo "Metadata already exists for: $filename"
        continue
    fi
    
    # Generate UUID (simple approach using date and random)
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')")
    
    # Get file info
    file_size=$(stat -f%z "$image_file" 2>/dev/null || stat -c%s "$image_file" 2>/dev/null || echo "0")
    file_time=$(stat -f%m "$image_file" 2>/dev/null || stat -c%Y "$image_file" 2>/dev/null || echo "$(date +%s)")
    
    # Convert timestamp to RFC3339 format
    timestamp=$(date -d "@$file_time" -Iseconds 2>/dev/null || date -r "$file_time" -Iseconds 2>/dev/null || date -Iseconds)
    
    # Create metadata JSON file
    metadata_file="$METADATA_DIR/$uuid.json"
    
    cat > "$metadata_file" << EOF
{
  "id": "$uuid",
  "original_name": "$filename",
  "filename": "$filename",
  "url": "$BASE_URL/$filename",
  "timestamp": "$timestamp",
  "preserve": false,
  "size": $file_size
}
EOF
    
    echo "Generated metadata for: $filename (ID: $uuid)"
    GENERATED=$((GENERATED + 1))
done

echo "Successfully generated metadata for $GENERATED files"
echo "Total metadata files now: $((EXISTING_METADATA + GENERATED))"