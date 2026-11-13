#!/usr/bin/env bash
set -e

PORT="${PORT:-10000}"
TS_KEY="${TAILSCALE_AUTH_KEY}"

echo "=========================================================="
echo "          STARTING RENDER TAILSCALE EGRESS RELAY          "
echo "=========================================================="

# 1. Start Tailscale daemon in unprivileged userspace networking mode
echo "[1/3] Launching userspace Tailscale daemon..."
/render/tailscaled \
  --tun=userspace-networking \
  --socks5-server=0.0.0.0:1080 \
  --outbound-http-proxy-listen=0.0.0.0:8080 \
  --state=/tmp/tailscaled.state \
  --socket=/tmp/tailscaled.sock > /tmp/tailscaled.log 2>&1 &

DAEMON_PID=$!
sleep 2

# 2. Authenticate to Tailnet
if [ -n "$TS_KEY" ]; then
    echo "[2/3] Connecting to Tailnet as render-proxy..."
    /render/tailscale --socket=/tmp/tailscaled.sock up \
      --authkey="$TS_KEY" \
      --hostname="render-proxy" \
      --reset
    NODE_IP=$(/render/tailscale --socket=/tmp/tailscaled.sock ip -4 || echo "unknown")
    echo "✔ Tailscale connected at Node IP: $NODE_IP"
else
    echo "[!] WARNING: TAILSCALE_AUTH_KEY is not set."
fi

# 3. Start Health & Telemetry HTTP Server on $PORT
echo "[3/3] Starting Health & Telemetry Server on port $PORT..."
exec python3 /render/server.py
