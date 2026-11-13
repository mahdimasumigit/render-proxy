#!/usr/bin/env bash
# Start Render Cloud Egress Proxy and Local SOCKS5 Bridge
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"

# 0. Load environment
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

if [ "$1" = "--restart" ] || [ "$1" = "-r" ]; then
    echo "Restart requested: recycling local SOCKS5 bridge..."
    pkill -f "render_bridge.py" 2>/dev/null || true
    sleep 1
fi

TS_KEY="${TAILSCALE_AUTH_KEY:-tskey-auth-khZkRKnnB111CNTRL-icus2h3inHiSByHLogSBHiwxKanvYoPEf}"
RENDER_KEY="${RENDER_API_KEY}"
REPO_URL="${RENDER_REPO_URL:-https://github.com/hosseinalipour/render-proxy}"

echo "=== [1/3] Starting Local Tailscale Daemon (Userspace) ==="
mkdir -p /tmp/local_ts
if ! pgrep -f "/tmp/local_ts/tailscaled.sock" >/dev/null; then
    /usr/sbin/tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1080 --outbound-http-proxy-listen=127.0.0.1:8080 --state=/tmp/local_ts/tailscaled.state --socket=/tmp/local_ts/tailscaled.sock >/tmp/local_ts/daemon.log 2>&1 &
    sleep 2
    tailscale --socket=/tmp/local_ts/tailscaled.sock up --authkey="$TS_KEY" --hostname="gut-client" --reset >/dev/null 2>&1
    echo "Local Tailscale client connected."
else
    echo "Local Tailscale client already running."
fi

echo "=== [2/3] Starting Local SOCKS5 Bridge (127.0.0.1:1086) ==="
if ! pgrep -f "render_bridge.py" >/dev/null; then
    nohup python3 "$DIR/render_bridge.py" >/tmp/render_bridge.log 2>&1 &
    echo "Local SOCKS5 Bridge started on 127.0.0.1:1086"
else
    echo "Local SOCKS5 Bridge already running on 127.0.0.1:1086"
fi

echo "=== [3/3] Checking / Launching Render Cloud Web Service ==="
if [ -z "$RENDER_KEY" ]; then
    echo "Error: RENDER_API_KEY is missing from $REPO_ROOT/.env."
    exit 1
fi

# Query existing services on Render
SERVICES_JSON=$(curl -s -H "Authorization: Bearer $RENDER_KEY" https://api.render.com/v1/services?name=render-proxy 2>/dev/null || true)
SERVICE_ID=$(echo "$SERVICES_JSON" | grep -o '"id":"srv-[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
SUSPENDED=$(echo "$SERVICES_JSON" | grep -o '"suspended":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
SERVICE_URL=$(echo "$SERVICES_JSON" | grep -o '"url":"https://[^"]*"' | head -n 1 | cut -d'"' -f4 || true)

if [ -n "$SERVICE_ID" ]; then
    if [ "$SUSPENDED" = "suspended" ]; then
        echo "Resuming suspended Render service: $SERVICE_ID..."
        curl -s -X POST -H "Authorization: Bearer $RENDER_KEY" "https://api.render.com/v1/services/$SERVICE_ID/resume" >/dev/null
        echo "Render service resumed!"
    else
        echo "Render cloud service is ALREADY RUNNING and healthy ($SERVICE_URL)."
    fi
else
    echo "Service 'render-proxy' does not exist yet. Deploying via Render API..."
    
    # Retrieve owner ID
    OWNER_JSON=$(curl -s -H "Authorization: Bearer $RENDER_KEY" https://api.render.com/v1/owners 2>/dev/null || true)
    OWNER_ID=$(echo "$OWNER_JSON" | grep -o '"id":"tea-[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
    if [ -z "$OWNER_ID" ]; then
        OWNER_ID=$(echo "$OWNER_JSON" | grep -o '"id":"usr-[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
    fi

    CREATE_PAYLOAD=$(cat <<EOF
{
  "type": "web_service",
  "name": "render-proxy",
  "ownerId": "$OWNER_ID",
  "repo": "$REPO_URL",
  "branch": "main",
  "serviceDetails": {
    "env": "docker",
    "plan": "free",
    "region": "frankfurt",
    "envVars": [
      {
        "key": "TAILSCALE_AUTH_KEY",
        "value": "$TS_KEY"
      }
    ]
  }
}
EOF
)
    RESP=$(curl -s -X POST \
      -H "Authorization: Bearer $RENDER_KEY" \
      -H "Content-Type: application/json" \
      -d "$CREATE_PAYLOAD" \
      https://api.render.com/v1/services)

    NEW_URL=$(echo "$RESP" | grep -o '"url":"https://[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
    if [ -n "$NEW_URL" ]; then
        echo "✔ Render Web Service created successfully: $NEW_URL"
    else
        echo "Render API response: $RESP"
    fi
fi

# Background keep-alive pinger (prevents Render free tier from sleeping after 15m)
if [ -n "$SERVICE_URL" ]; then
    if ! pgrep -f "render_keepalive" >/dev/null; then
        (while true; do
            curl -s "$SERVICE_URL/health" >/dev/null 2>&1 || true
            sleep 600
        done) >/dev/null 2>&1 &
        echo "Keep-Alive worker active (pings $SERVICE_URL every 10m to prevent sleep)."
    fi
fi

echo "=========================================================="
echo "SOCKS5 Proxy Ready: 127.0.0.1:1086 (Check 'Proxy DNS via SOCKS v5')"
echo "=========================================================="
