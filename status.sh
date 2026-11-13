#!/usr/bin/env bash
# Render SOCKS5 Proxy & Cloud Relay Status Inspector
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

RENDER_KEY="${RENDER_API_KEY}"
TS_SOCK="/tmp/local_ts/tailscaled.sock"
TS_CLI="/usr/bin/tailscale"

echo -e "${BOLD}${CYAN}======================================================================${NC}"
echo -e "${BOLD}${CYAN}          RENDER EGRESS RELAY & SOCKS5 PROXY STATUS                   ${NC}"
echo -e "${BOLD}${CYAN}======================================================================${NC}"

ALL_OK=true

# 1. Local Tailscale Daemon
echo -ne " [1/5] Local Tailscale Daemon: "
if pgrep -f "$TS_SOCK" >/dev/null 2>&1; then
    TS_PID=$(pgrep -f "$TS_SOCK" | head -n 1)
    echo -e "${GREEN}RUNNING${NC} (PID: $TS_PID, Socket: $TS_SOCK)"
else
    echo -e "${RED}STOPPED${NC} (No tailscaled daemon running)"
    ALL_OK=false
fi

# 2. Local Python Bridge (Port 1086)
echo -ne " [2/5] Local SOCKS5 Bridge:    "
if pgrep -f "render_bridge.py" >/dev/null 2>&1; then
    BRIDGE_PID=$(pgrep -f "render_bridge.py" | head -n 1)
    echo -e "${GREEN}LISTENING${NC} (PID: $BRIDGE_PID, Port: 127.0.0.1:1086)"
else
    echo -e "${RED}STOPPED${NC} (render_bridge.py is not running)"
    ALL_OK=false
fi

# 3. Render Cloud Web Service Status
echo -ne " [3/5] Render Cloud Service:   "
if [ -n "$RENDER_KEY" ]; then
    SERVICES_JSON=$(curl -s -H "Authorization: Bearer $RENDER_KEY" https://api.render.com/v1/services?name=render-proxy 2>/dev/null || true)
    SERVICE_ID=$(echo "$SERVICES_JSON" | grep -o '"id":"srv-[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
    SUSPENDED=$(echo "$SERVICES_JSON" | grep -o '"suspended":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
    SERVICE_URL=$(echo "$SERVICES_JSON" | grep -o '"url":"https://[^"]*"' | head -n 1 | cut -d'"' -f4 || true)

    if [ -n "$SERVICE_ID" ]; then
        if [ "$SUSPENDED" = "suspended" ]; then
            echo -e "${YELLOW}SUSPENDED${NC} (Service paused to save free hours. Run ./start.sh to resume)"
            ALL_OK=false
        else
            echo -e "${GREEN}LIVE${NC} (ID: $SERVICE_ID, URL: $SERVICE_URL)"
        fi
    else
        echo -e "${YELLOW}NOT FOUND${NC} (No service named 'render-proxy' found on Render account)"
        ALL_OK=false
    fi
else
    echo -e "${YELLOW}SKIPPED${NC} (RENDER_API_KEY not configured in .env)"
fi

# 4. Tailscale Mesh Peering Status
echo -ne " [4/5] Tailscale Mesh Peer:    "
if [ -S "$TS_SOCK" ] && [ -x "$TS_CLI" ]; then
    TS_STATUS=$("$TS_CLI" --socket="$TS_SOCK" status 2>/dev/null || true)
    PROXY_LINE=$(echo "$TS_STATUS" | grep "render-proxy" | head -n 1)
    if [ -n "$PROXY_LINE" ]; then
        PROXY_IP=$(echo "$PROXY_LINE" | awk '{print $1}')
        if echo "$PROXY_LINE" | grep -q "offline"; then
            echo -e "${YELLOW}OFFLINE${NC} (Peer $PROXY_IP seen recently, not connected)"
            ALL_OK=false
        else
            PING_OUT=$("$TS_CLI" --socket="$TS_SOCK" ping --c=1 --until-direct=false render-proxy 2>/dev/null || true)
            if echo "$PING_OUT" | grep -q "via"; then
                PING_ENDPOINT=$(echo "$PING_OUT" | grep "via" | sed 's/.*via //; s/ in .*//')
                PING_MS=$(echo "$PING_OUT" | grep "via" | sed 's/.* in //')
                if echo "$PING_ENDPOINT" | grep -q -i "derp"; then
                    echo -e "${YELLOW}ONLINE (DERP TCP Relay)${NC} (IP: $PROXY_IP, Relay: $PING_ENDPOINT, Latency: $PING_MS)"
                else
                    echo -e "${GREEN}ONLINE (Direct UDP)${NC} (IP: $PROXY_IP, Endpoint: $PING_ENDPOINT, Latency: $PING_MS)"
                fi
            else
                echo -e "${GREEN}ONLINE${NC} (IP: $PROXY_IP)"
            fi
        fi
    else
        echo -e "${RED}NOT FOUND${NC} (render-proxy not listed in Tailnet)"
        ALL_OK=false
    fi
else
    echo -e "${RED}UNAVAILABLE${NC} (Tailscale socket not reachable)"
    ALL_OK=false
fi

# 5. End-to-End Egress Probe
echo -ne " [5/5] End-to-End Egress Test: "
PROBE_RES=$(curl -x socks5h://127.0.0.1:1086 --connect-timeout 5 -s https://api.ipify.org 2>/dev/null || true)
if [ -n "$PROBE_RES" ] && [[ "$PROBE_RES" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${GREEN}PASS${NC} (Exit IP: ${BOLD}$PROBE_RES${NC})"
else
    echo -e "${RED}FAIL${NC} (Cannot route external traffic through 127.0.0.1:1086)"
    ALL_OK=false
fi

echo -e "${BOLD}${CYAN}----------------------------------------------------------------------${NC}"
if [ "$ALL_OK" = true ]; then
    echo -e "${BOLD}${GREEN}✔ RENDER PROXY IS HEALTHY AND OPERATIONAL${NC}"
    echo -e "Browser configuration: SOCKS5 -> 127.0.0.1:1086 (Proxy DNS via SOCKS5 enabled)"
else
    echo -e "${BOLD}${RED}✖ RENDER PROXY IS CURRENTLY DOWN OR DEGRADED${NC}"
    echo -e "To start or repair: ${CYAN}$DIR/start.sh${NC}"
fi
echo -e "${BOLD}${CYAN}======================================================================${NC}"
