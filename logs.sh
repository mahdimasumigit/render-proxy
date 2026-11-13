#!/usr/bin/env bash
# Render Server Logs Inspector
# Fetches real-time runtime logs from the cloud worker over Tailnet or Render API.
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"

# Load .env if present
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

TS_SOCK="/tmp/local_ts/tailscaled.sock"

fetch_live_logs() {
    # Attempt 1: Fetch directly from Render container over Tailscale telemetry endpoint
    if [ -S "$TS_SOCK" ] && pgrep -f "$TS_SOCK" >/dev/null 2>&1; then
        LIVE_LOGS=$(curl -s --max-time 4 -x socks5h://127.0.0.1:1080 http://render-proxy:10000/logs 2>/dev/null || true)
        if [ -n "$LIVE_LOGS" ] && [[ "$LIVE_LOGS" == *"RENDER CLOUD RELAY LOGS"* ]]; then
            echo "$LIVE_LOGS"
            return 0
        fi
    fi

    # Attempt 2: Fetch via Render API deploys
    if [ -n "$RENDER_API_KEY" ]; then
        SERVICES_JSON=$(curl -s -H "Authorization: Bearer $RENDER_API_KEY" https://api.render.com/v1/services?name=render-proxy 2>/dev/null || true)
        SERVICE_ID=$(echo "$SERVICES_JSON" | grep -o '"id":"srv-[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
        if [ -n "$SERVICE_ID" ]; then
            DEPLOYS_JSON=$(curl -s -H "Authorization: Bearer $RENDER_API_KEY" "https://api.render.com/v1/services/$SERVICE_ID/deploys?limit=1" 2>/dev/null || true)
            DEPLOY_STATUS=$(echo "$DEPLOYS_JSON" | grep -o '"status":"[^"]*"' | head -n 1 | cut -d'"' -f4 || echo "unknown")
            echo "=== [Render Cloud Deploy Status: $DEPLOY_STATUS] ==="
            echo "(Container is building/deploying or waiting for incoming requests)"
            return 0
        fi
    fi

    echo "Error: Cannot reach Render telemetry endpoint or Render API."
    return 1
}

if [ "$1" = "-f" ] || [ "$1" = "--follow" ]; then
    echo "Streaming logs from Render Relay (Ctrl+C to stop)..."
    while true; do
        [ -t 1 ] && clear
        fetch_live_logs || true
        sleep 5
    done
else
    fetch_live_logs
fi
