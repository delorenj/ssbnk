#!/bin/sh

# ssbnk cleanup script
# Runs daily to archive old screenshots and clean up archives

set -e

DATA_DIR="/data"
HOSTED_DIR="$DATA_DIR/hosted"
ARCHIVE_DIR="$DATA_DIR/archive"
METADATA_DIR="$DATA_DIR/metadata"
RETENTION_DAYS=${SSBNK_RETENTION_DAYS:-30}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CLEANUP] $1"
}

log "Starting cleanup process..."

# Create archive directory if it doesn't exist
mkdir -p "$ARCHIVE_DIR"

# Get today's date for archive folder
TODAY=$(date '+%Y-%m-%d')
ARCHIVE_TODAY="$ARCHIVE_DIR/$TODAY"

# Calculate cutoff time (files older than retention days should be archived)
CUTOFF_TIMESTAMP=$(date -d "$RETENTION_DAYS days ago" '+%s' 2>/dev/null || echo $(($(date '+%s') - RETENTION_DAYS * 86400)))

# Count files to be archived (only old files)
FILES_TO_ARCHIVE=0
for file in "$HOSTED_DIR"/*; do
    if [ -f "$file" ]; then
        # Get file modification time
        FILE_TIMESTAMP=$(stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null || echo 0)
        if [ "$FILE_TIMESTAMP" -lt "$CUTOFF_TIMESTAMP" ]; then
            FILES_TO_ARCHIVE=$((FILES_TO_ARCHIVE + 1))
        fi
    fi
done

if [ "$FILES_TO_ARCHIVE" -gt 0 ]; then
    log "Archiving $FILES_TO_ARCHIVE old files to $ARCHIVE_TODAY"
    
    # Create today's archive directory only if we have files to archive
    mkdir -p "$ARCHIVE_TODAY"
    
    # Move old image files to archive (except those marked as preserve)
    for file in "$HOSTED_DIR"/*; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            
            # Get file modification time
            FILE_TIMESTAMP=$(stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null || echo 0)
            
            # Only archive files older than retention period
            if [ "$FILE_TIMESTAMP" -lt "$CUTOFF_TIMESTAMP" ]; then
                # Check if file should be preserved
                preserve=false
                for metadata_file in "$METADATA_DIR"/*.json; do
                    if [ -f "$metadata_file" ]; then
                        if grep -q "\"filename\".*\"$filename\"" "$metadata_file" && grep -q "\"preserve\".*true" "$metadata_file"; then
                            preserve=true
                            break
                        fi
                    fi
                done
                
                if [ "$preserve" = false ]; then
                    mv "$file" "$ARCHIVE_TODAY/"
                    log "Archived: $filename"
                else
                    log "Preserved: $filename"
                fi
            fi
        fi
    done
    
    # Archive corresponding metadata files
    for metadata_file in "$METADATA_DIR"/*.json; do
        if [ -f "$metadata_file" ]; then
            filename=$(grep -o '"filename"[^,]*' "$metadata_file" | cut -d'"' -f4)
            if [ ! -f "$HOSTED_DIR/$filename" ] && [ -f "$ARCHIVE_TODAY/$filename" ]; then
                mv "$metadata_file" "$ARCHIVE_TODAY/"
                log "Archived metadata for: $filename"
            fi
        fi
    done
else
    log "No old files to archive"
fi

# Clean up old archives (older than retention period)
log "Cleaning up archives older than $RETENTION_DAYS days..."

# Calculate cutoff date for archive cleanup (Alpine-compatible)
CUTOFF_SECONDS=$(($(date '+%s') - RETENTION_DAYS * 86400))
CUTOFF_DATE=$(date -d "@$CUTOFF_SECONDS" '+%Y-%m-%d' 2>/dev/null || date -r "$CUTOFF_SECONDS" '+%Y-%m-%d' 2>/dev/null || echo "1970-01-01")
DELETED_COUNT=0

for archive_dir in "$ARCHIVE_DIR"/*; do
    if [ -d "$archive_dir" ]; then
        archive_date=$(basename "$archive_dir")
        
        # Compare dates (simple string comparison works for YYYY-MM-DD format)
        if [ "$archive_date" \< "$CUTOFF_DATE" ]; then
            log "Deleting old archive: $archive_date"
            rm -rf "$archive_dir"
            DELETED_COUNT=$((DELETED_COUNT + 1))
        fi
    fi
done

if [ "$DELETED_COUNT" -gt 0 ]; then
    log "Deleted $DELETED_COUNT old archive directories"
else
    log "No old archives to delete"
fi

# Clean up orphaned metadata files
log "Cleaning up orphaned metadata files..."
ORPHANED_COUNT=0

for metadata_file in "$METADATA_DIR"/*.json; do
    if [ -f "$metadata_file" ]; then
        filename=$(grep -o '"filename"[^,]*' "$metadata_file" | cut -d'"' -f4 2>/dev/null || echo "")
        if [ -n "$filename" ] && [ ! -f "$HOSTED_DIR/$filename" ]; then
            # Check if file exists in any archive
            found=false
            for archive_dir in "$ARCHIVE_DIR"/*; do
                if [ -f "$archive_dir/$filename" ]; then
                    found=true
                    break
                fi
            done
            
            if [ "$found" = false ]; then
                log "Removing orphaned metadata: $(basename "$metadata_file")"
                rm "$metadata_file"
                ORPHANED_COUNT=$((ORPHANED_COUNT + 1))
            fi
        fi
    fi
done

if [ "$ORPHANED_COUNT" -gt 0 ]; then
    log "Removed $ORPHANED_COUNT orphaned metadata files"
else
    log "No orphaned metadata files found"
fi

# Report storage usage
HOSTED_SIZE=$(du -sh "$HOSTED_DIR" 2>/dev/null | cut -f1 || echo "0")
ARCHIVE_SIZE=$(du -sh "$ARCHIVE_DIR" 2>/dev/null | cut -f1 || echo "0")
TOTAL_FILES=$(find "$HOSTED_DIR" -type f | wc -l)

log "Cleanup completed successfully"
log "Storage usage - Hosted: $HOSTED_SIZE, Archives: $TOTAL_FILES files, Archives: $ARCHIVE_SIZE"
