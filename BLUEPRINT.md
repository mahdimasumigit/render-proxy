# Render.com Anti-Blackout Egress Relay: Reproducing Blueprint

A self-contained, linear guide to deploy, monitor, start, and stop a 24/7 cloud egress relay on Render.com using Tailscale userspace networking.

---

## 1. The Core Idea
* Render.com provides a **Free Web Service** tier (0.1 CPU, 512 MB RAM, 750 free hours/month).
* Unlike Kaggle (which has a 12-hour session limit), Render runs **24/7 continuously**.
* **Shecan DNS Support**: `render.com` is actively mirrored by Shecan (`50.7.177.110`, `94.130.13.19`), meaning both Render's API and the deployed services remain accessible even during foreign IP blackouts.
* Tailscale runs in unprivileged userspace mode inside the Render container, connecting to your Tailnet as `render-proxy` without requiring root or kernel TUN privileges.
* A local SOCKS5 bridge on `127.0.0.1:1086` routes your browser traffic directly to `render-proxy:8080`.

---

## 2. Requirements & Setup
1. **Render Account & API Key**:
   * Generate an API key from `https://dashboard.render.com/u/settings` > *API Keys*.
   * Add to `.env`:
     ```bash
     RENDER_API_KEY="rnd_..."
     ```
2. **Tailscale Auth Key**:
   * Add to `.env`:
     ```bash
     TAILSCALE_AUTH_KEY="tskey-auth-..."
     ```
3. **GitHub Repository**:
   * Create and push this directory to a public repository (e.g. `https://github.com/hosseinalipour/render-proxy`) using `gh`:
     ```bash
     cd render-blueprint
     git init
     gh repo create render-proxy --public --source=. --remote=origin --push
     ```

---

## 3. How We Overcame Render Constraints

1. **Free Tier Sleep Prevention (15-Minute Timeout)**:
   * Render free Web Services spin down after 15 minutes of inactivity if no HTTP traffic hits their public URL.
   * `start.sh` automatically launches a background keep-alive worker that pings `https://<service>.onrender.com/health` every 10 minutes, keeping the container permanently awake 24/7.
2. **Web Port Health Check Requirement**:
   * Render requires all Web Services to bind to `$PORT` (default 10000) and return HTTP 200.
   * `server.py` runs a lightweight HTTP server on `$PORT` answering `/` and `/health`, while Tailscale operates in the background on ports `1080` (SOCKS5) and `8080` (HTTP CONNECT).
3. **Unprivileged Userspace Networking**:
   * Docker containers on Render do not have `CAP_NET_ADMIN` or `/dev/net/tun`.
   * Tailscale runs with `--tun=userspace-networking`, creating an in-memory network stack.

---

## 4. How to Use

### Start / Resume Proxy:
```bash
./start.sh
# To force restart:
./start.sh --restart
```

### Check Status:
```bash
./status.sh
```

### Stop / Suspend (Save Hours):
```bash
./stop.sh
```
*Suspends the service via Render API so 0 free hours are consumed when you are not using it.*

---

## 5. Browser / App Configuration
* **Proxy Protocol:** `SOCKS5` (or `SOCKS v5`)
* **Host / IP:** `127.0.0.1`
* **Port:** `1086`
* **Proxy DNS when using SOCKS v5:** **Enabled (Checked)**
