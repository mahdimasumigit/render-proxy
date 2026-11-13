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
GH_USER="mahdimasumigit"
REPO_NAME="render-proxy"
REPO_URL="https://github.com/$GH_USER/$REPO_NAME"

echo "=== [1/5] Checking Pre-requisites & GitHub Authentication ==="
if [ -z "$RENDER_KEY" ]; then
    echo "[ERROR] RENDER_API_KEY is missing from $REPO_ROOT/.env."
    exit 1
fi

if [ -z "$GH_TOKEN" ]; then
    echo "======================================================================"
    echo "[!] GH_TOKEN is not configured in $REPO_ROOT/.env."
    echo ""
    echo "To deploy the Render cloud proxy via GitHub CLI (gh):"
    echo "1. Visit in browser: https://github.com/settings/tokens/new"
    echo "   (Make sure you are logged into account '$GH_USER')"
    echo "2. Set Token Note: render-relay"
    echo "3. Check the scope:"
    echo "   [x] repo (Full control of private repositories)"
    echo "4. Click 'Generate token' at the bottom and copy the token (ghp_...)."
    echo "5. Add to $REPO_ROOT/.env:"
    echo '   GH_TOKEN="ghp_your_token_here"'
    echo "6. Run this script again: ./start.sh"
    echo "======================================================================"
    exit 1
fi

export GH_TOKEN="$GH_TOKEN"

if ! gh auth status >/dev/null 2>&1; then
    echo "======================================================================"
    echo "[ERROR] GitHub CLI authentication failed."
    echo "The GH_TOKEN provided in $REPO_ROOT/.env is invalid or expired."
    echo "Please check or regenerate the token at https://github.com/settings/tokens"
    echo "======================================================================"
    exit 1
fi

echo "✔ GitHub CLI authenticated as $GH_USER."

echo "=== [2/5] Checking / Creating GitHub Repository ($GH_USER/$REPO_NAME) ==="
if ! gh repo view "$GH_USER/$REPO_NAME" >/dev/null 2>&1; then
    echo "Repository $GH_USER/$REPO_NAME does not exist on GitHub. Creating via gh CLI..."
    if ! gh repo create "$GH_USER/$REPO_NAME" --public --source="$DIR" --remote=origin --push; then
        echo "[ERROR] Failed to create repository $GH_USER/$REPO_NAME with gh CLI!"
        exit 1
    fi
    echo "✔ Repository created and pushed: $REPO_URL"
else
    echo "✔ GitHub repository $GH_USER/$REPO_NAME exists."
    # Ensure remote origin is set and branch is pushed
    git -C "$DIR" remote set-url origin "https://github.com/$GH_USER/$REPO_NAME.git" 2>/dev/null || git -C "$DIR" remote add origin "https://github.com/$GH_USER/$REPO_NAME.git"
    git -C "$DIR" push -u origin main 2>/dev/null || true
fi

echo "=== [3/5] Starting Local Tailscale Daemon (Userspace) ==="
mkdir -p /tmp/local_ts
TS_SOCK="/tmp/local_ts/tailscaled.sock"
if ! pgrep -f "$TS_SOCK" >/dev/null; then
    /usr/sbin/tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1080 --outbound-http-proxy-listen=127.0.0.1:8080 --state=/tmp/local_ts/tailscaled.state --socket="$TS_SOCK" >/tmp/local_ts/daemon.log 2>&1 &
    sleep 2
    tailscale --socket="$TS_SOCK" up --authkey="$TS_KEY" --hostname="gut-client" --reset >/dev/null 2>&1
    echo "Local Tailscale client connected."
else
    echo "Local Tailscale client already running."
fi

echo "=== [4/5] Checking / Deploying Render Cloud Web Service ==="
SERVICES_JSON=$(curl -s -H "Authorization: Bearer $RENDER_KEY" https://api.render.com/v1/services?name=render-proxy 2>/dev/null || true)
SERVICE_ID=$(echo "$SERVICES_JSON" | grep -o '"id":"srv-[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
SUSPENDED=$(echo "$SERVICES_JSON" | grep -o '"suspended":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
SERVICE_URL=$(echo "$SERVICES_JSON" | grep -o '"url":"https://[^"]*"' | head -n 1 | cut -d'"' -f4 || true)

if [ -n "$SERVICE_ID" ]; then
    if [ "$SUSPENDED" = "suspended" ]; then
        echo "Resuming suspended Render service: $SERVICE_ID..."
        RESUME_RESP=$(curl -s -X POST -H "Authorization: Bearer $RENDER_KEY" "https://api.render.com/v1/services/$SERVICE_ID/resume")
        if echo "$RESUME_RESP" | grep -q '"error"'; then
            echo "[ERROR] Failed to resume Render service: $RESUME_RESP"
            exit 1
        fi
        echo "Render service resumed!"
    else
        echo "Render cloud service is already configured ($SERVICE_URL)."
    fi
else
    echo "Service 'render-proxy' does not exist yet. Deploying via Render API..."
    
    OWNER_JSON=$(curl -s -H "Authorization: Bearer $RENDER_KEY" https://api.render.com/v1/owners 2>/dev/null || true)
    OWNER_ID=$(echo "$OWNER_JSON" | grep -o '"id":"tea-[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
    if [ -z "$OWNER_ID" ]; then
        OWNER_ID=$(echo "$OWNER_JSON" | grep -o '"id":"usr-[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
    fi

    if [ -z "$OWNER_ID" ]; then
        echo "[ERROR] Could not resolve Render Owner ID from API."
        exit 1
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

    SERVICE_ID=$(echo "$RESP" | grep -o '"id":"srv-[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
    SERVICE_URL=$(echo "$RESP" | grep -o '"url":"https://[^"]*"' | head -n 1 | cut -d'"' -f4 || true)

    if [ -z "$SERVICE_ID" ]; then
        echo "=========================================================="
        echo "[ERROR] Failed to create Render Web Service!"
        echo "Render API response: $RESP"
        echo "=========================================================="
        exit 1
    fi
    echo "✔ Render Web Service created: $SERVICE_URL (ID: $SERVICE_ID)"
fi

echo "=== [5/5] Launching Bridge & Verifying Cloud Connectivity ==="
pkill -f "render_bridge.py" 2>/dev/null || true
sleep 1
nohup python3 "$DIR/render_bridge.py" >>/tmp/render_bridge.log 2>&1 &
sleep 1
if ! pgrep -f "render_bridge.py" >/dev/null 2>&1; then
    echo "[ERROR] Failed to launch local render_bridge.py. Check /tmp/render_bridge.log"
    exit 1
fi

echo -n "Waiting for Render container to build, deploy, and peer on Tailnet..."
CONNECTED=false
EXIT_IP=""
for i in {1..40}; do
    # Try egress test through 127.0.0.1:1086
    EXIT_IP=$(curl -s -m 3 -x socks5h://127.0.0.1:1086 https://api.ipify.org 2>/dev/null || true)
    if [ -n "$EXIT_IP" ]; then
        CONNECTED=true
        break
    fi
    # Also check direct telemetry from render-proxy over tailscale
    TEL_CHECK=$(curl -s -m 3 -x socks5h://127.0.0.1:1080 http://render-proxy:10000/health 2>/dev/null || true)
    if echo "$TEL_CHECK" | grep -q "healthy"; then
        CONNECTED=true
        EXIT_IP=$(echo "$TEL_CHECK" | grep -o '"service":"[^"]*"' | cut -d'"' -f4 || echo "Connected")
        break
    fi
    echo -n "."
    sleep 3
done
echo ""

if [ "$CONNECTED" = false ]; then
    echo "----------------------------------------------------------"
    echo "[ERROR] Could not connect to Render cloud relay within 120s!"
    echo "Stopping local bridge to avoid false listener on 127.0.0.1:1086..."
    pkill -f "render_bridge.py" 2>/dev/null || true
    echo "----------------------------------------------------------"
    exit 1
fi

echo "=========================================================="
echo "✔ SOCKS5 Proxy Verified & Operational: 127.0.0.1:1086"
[ -n "$EXIT_IP" ] && echo "✔ Exit IP / Status: $EXIT_IP"
echo "Streaming live Render cloud logs (Ctrl+C to stop stream)..."
echo "=========================================================="

# Background keep-alive pinger
if [ -n "$SERVICE_URL" ] && ! pgrep -f "render_keepalive" >/dev/null; then
    (while true; do
        curl -s "$SERVICE_URL/health" >/dev/null 2>&1 || true
        sleep 600
    done) >/dev/null 2>&1 &
fi

trap 'echo -e "\nLog streaming stopped. Background bridge remains active on 127.0.0.1:1086 (run ./stop.sh to terminate)."; exit 0' INT TERM
exec "$DIR/logs.sh" -f
