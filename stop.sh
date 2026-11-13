#!/usr/bin/env bash
# Stop Render Cloud Relay and Local Bridge
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

echo "=== [1/2] Suspending Render Cloud Service ==="
if [ -n "$RENDER_API_KEY" ]; then
    SERVICES_JSON=$(curl -s -H "Authorization: Bearer $RENDER_API_KEY" https://api.render.com/v1/services?name=render-proxy 2>/dev/null || true)
    SERVICE_ID=$(echo "$SERVICES_JSON" | grep -o '"id":"srv-[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
    if [ -n "$SERVICE_ID" ]; then
        curl -s -X POST -H "Authorization: Bearer $RENDER_API_KEY" "https://api.render.com/v1/services/$SERVICE_ID/suspend" >/dev/null || true
        echo "Render service $SERVICE_ID suspended (consuming 0 free hours)."
    else
        echo "No active render-proxy service found on Render."
    fi
else
    echo "RENDER_API_KEY not found in .env; skipping cloud suspension."
fi

echo "=== [2/2] Stopping Local SOCKS5 Bridge ==="
pkill -f "render_bridge.py" 2>/dev/null || true
echo "Local Render bridge (127.0.0.1:1086) stopped."
