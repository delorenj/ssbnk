#!/bin/bash

# Force Screenshot Sync from Local to Remote
# Run this on your LOCAL machine after taking screenshots

API_KEY="CAGmzQmefZA5ykZTv5EhK45KfXw3zq6f"
REMOTE_HOST="big-0chungus"
REMOTE_PORT="8384"

echo "🩸 Force Screenshot Sync to $REMOTE_HOST"

# Function to trigger sync on local machine
force_local_sync() {
    echo "📤 Triggering local Syncthing scan..."
    # This should be run on your LOCAL machine
    curl -s -X POST -H "X-API-Key: YOUR_LOCAL_API_KEY" \
      "http://localhost:8384/rest/db/scan?folder=ss" > /dev/null
    
    if [ $? -eq 0 ]; then
        echo "✅ Local scan triggered"
    else
        echo "❌ Failed to trigger local scan"
    fi
}

# Function to trigger sync on remote machine
force_remote_sync() {
    echo "📥 Triggering remote Syncthing scan..."
    curl -s -X POST -H "X-API-Key: $API_KEY" \
      "http://$REMOTE_HOST:$REMOTE_PORT/rest/db/scan?folder=ss" > /dev/null
    
    if [ $? -eq 0 ]; then
        echo "✅ Remote scan triggered"
    else
        echo "❌ Failed to trigger remote scan"
    fi
}

# Function to check sync status
check_sync_status() {
    echo "📊 Checking sync status..."
    
    # Check remote folder status
    status=$(curl -s -H "X-API-Key: $API_KEY" \
      "http://$REMOTE_HOST:$REMOTE_PORT/rest/db/status?folder=ss" | jq -r '.state')
    
    echo "Remote folder state: $status"
    
    # Check completion for each device
    echo "Device completion status:"
    curl -s -H "X-API-Key: $API_KEY" \
      "http://$REMOTE_HOST:$REMOTE_PORT/rest/db/completion?folder=ss" | \
      jq -r '"Completion: \(.completion)% | Need: \(.needItems) items"'
}

# Main execution
echo "Starting sync process..."

# Force scans
force_local_sync
sleep 2
force_remote_sync
sleep 3

# Check status
check_sync_status

echo ""
echo "💡 To use this script on your LOCAL machine:"
echo "1. Replace YOUR_LOCAL_API_KEY with your local Syncthing API key"
echo "2. Run: ./scripts/force-screenshot-sync.sh"
echo ""
echo "🔍 To find your local API key:"
echo "grep -o '<apikey>[^<]*' ~/.local/state/syncthing/config.xml | cut -d'>' -f2"
