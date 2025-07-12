#!/bin/bash

# Quick Manual Sync Command
# Run this on big-0chungus to force immediate sync check

API_KEY="CAGmzQmefZA5ykZTv5EhK45KfXw3zq6f"

echo "🔄 Forcing immediate sync check..."

# Trigger rescan
curl -s -X POST -H "X-API-Key: $API_KEY" \
  "http://localhost:8384/rest/db/scan?folder=ss" > /dev/null

if [ $? -eq 0 ]; then
    echo "✅ Sync triggered"
    
    # Wait a moment and check status
    sleep 3
    
    status=$(curl -s -H "X-API-Key: $API_KEY" \
      "http://localhost:8384/rest/db/status?folder=ss" | jq -r '.state')
    
    completion=$(curl -s -H "X-API-Key: $API_KEY" \
      "http://localhost:8384/rest/db/completion?folder=ss" | jq -r '.completion')
    
    echo "📊 Status: $status | Completion: ${completion}%"
    
    # Check for pending items
    need_items=$(curl -s -H "X-API-Key: $API_KEY" \
      "http://localhost:8384/rest/db/completion?folder=ss" | jq -r '.needItems')
    
    if [ "$need_items" -gt 0 ]; then
        echo "⏳ Still waiting for $need_items items to sync"
    else
        echo "✅ All items synced!"
    fi
else
    echo "❌ Failed to trigger sync"
fi
