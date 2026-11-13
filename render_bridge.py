#!/usr/bin/env python3
"""
Render Tailscale Local SOCKS5 Bridge
Listens on 127.0.0.1:1086 (SOCKS5) and forwards traffic dynamically through
Render's Tailscale HTTP CONNECT proxy (render-proxy:8080) via local userspace Tailscale.
"""
import asyncio
import socket
import struct
import logging
import sys

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

LOCAL_HOST = "127.0.0.1"
LOCAL_PORT = 1086

TS_LOCAL_PROXY = ("127.0.0.1", 1080)
RENDER_TS_HOST = "render-proxy"
RENDER_TS_PORT = 8080
TS_SOCKET_PATH = "/tmp/local_ts/tailscaled.sock"

def set_socket_options(transport):
    """Enable TCP_NODELAY to disable Nagle algorithm and reduce latency."""
    try:
        sock = transport.get_extra_info("socket")
        if sock:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    except Exception:
        pass

async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass

async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    set_socket_options(writer)
    try:
        await asyncio.wait_for(_do_handshake(reader, writer), timeout=12.0)
    except asyncio.TimeoutError:
        logging.warning("Handshake timed out after 12s; closing connection")
        try:
            writer.write(b"\x05\x04\x00\x01\x00\x00\x00\x00\x00\x00")
            await writer.drain()
        except Exception:
            pass
        writer.close()
    except Exception as e:
        logging.debug(f"Connection error: {e}")
        writer.close()

async def _do_handshake(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    # 1. SOCKS5 Greeting
    header = await reader.readexactly(2)
    version, nmethods = struct.unpack("!BB", header)
    if version != 5:
        writer.close()
        return
    methods = await reader.readexactly(nmethods)
    writer.write(b"\x05\x00")
    await writer.drain()

    # 2. SOCKS5 Request
    req_header = await reader.readexactly(4)
    ver, cmd, rsv, atyp = struct.unpack("!BBBB", req_header)
    if cmd != 1:  # Only CONNECT supported
        writer.write(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
        await writer.drain()
        writer.close()
        return

    if atyp == 1:  # IPv4
        addr_bytes = await reader.readexactly(4)
        dest_host = socket.inet_ntoa(addr_bytes)
    elif atyp == 3:  # Domain
        domain_len = (await reader.readexactly(1))[0]
        dest_host = (await reader.readexactly(domain_len)).decode("utf-8")
    elif atyp == 4:  # IPv6
        addr_bytes = await reader.readexactly(16)
        dest_host = socket.inet_ntop(socket.AF_INET6, addr_bytes)
    else:
        writer.close()
        return

    port_bytes = await reader.readexactly(2)
    dest_port = struct.unpack("!H", port_bytes)[0]

    logging.info(f"Target: {dest_host}:{dest_port}")

    # 3. Connect to Render proxy via local Tailscale SOCKS5 daemon
    ts_reader, ts_writer = await asyncio.open_connection(TS_LOCAL_PROXY[0], TS_LOCAL_PROXY[1])
    set_socket_options(ts_writer)

    ts_writer.write(b"\x05\x01\x00")
    await ts_writer.drain()
    ts_auth_resp = await ts_reader.readexactly(2)
    if ts_auth_resp != b"\x05\x00":
        writer.close()
        ts_writer.close()
        return

    # SOCKS5 Connect to Render by MagicDNS name (render-proxy:8080)
    host_bytes = RENDER_TS_HOST.encode("utf-8")
    port_bytes = struct.pack("!H", RENDER_TS_PORT)
    ts_writer.write(b"\x05\x01\x00\x03" + bytes([len(host_bytes)]) + host_bytes + port_bytes)
    await ts_writer.drain()
    ts_conn_resp = await ts_reader.readexactly(10)
    if ts_conn_resp[1] != 0:
        logging.error(f"Failed to connect to Render proxy: code {ts_conn_resp[1]}")
        writer.write(b"\x05\x04\x00\x01\x00\x00\x00\x00\x00\x00")
        await writer.drain()
        writer.close()
        ts_writer.close()
        return

    # 4. Send HTTP CONNECT to Render proxy for the real destination
    connect_req = f"CONNECT {dest_host}:{dest_port} HTTP/1.1\r\nHost: {dest_host}:{dest_port}\r\n\r\n"
    ts_writer.write(connect_req.encode("utf-8"))
    await ts_writer.drain()

    # Read HTTP CONNECT response (read until \r\n\r\n)
    header_buf = b""
    while b"\r\n\r\n" not in header_buf:
        chunk = await ts_reader.read(1024)
        if not chunk:
            break
        header_buf += chunk

    first_line = header_buf.split(b"\r\n")[0].decode("utf-8", errors="replace")
    if "200" not in first_line:
        logging.error(f"Render CONNECT failed for {dest_host}:{dest_port}: {first_line}")
        writer.write(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
        await writer.drain()
        writer.close()
        ts_writer.close()
        return

    # 5. Tell client: SOCKS5 Connection established
    writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
    await writer.drain()

    # 6. Bi-directional data streaming
    done, pending = await asyncio.wait(
        [asyncio.create_task(pipe(reader, ts_writer)), asyncio.create_task(pipe(ts_reader, writer))],
        return_when=asyncio.FIRST_COMPLETED
    )
    for task in pending:
        task.cancel()

async def udp_nat_keepalive_daemon():
    """
    Periodically pings the Render node through Tailscale to keep the direct
    WireGuard UDP NAT mapping open at the ISP gateway.
    """
    ts_cli = "/usr/bin/tailscale"
    while True:
        await asyncio.sleep(20)
        try:
            proc = await asyncio.create_subprocess_exec(
                ts_cli, f"--socket={TS_SOCKET_PATH}", "ping", "--c=1", "--until-direct=false", RENDER_TS_HOST,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL
            )
            await asyncio.wait_for(proc.wait(), timeout=6.0)
        except Exception:
            pass

async def main():
    asyncio.create_task(udp_nat_keepalive_daemon())
    server = await asyncio.start_server(handle_client, LOCAL_HOST, LOCAL_PORT)
    logging.info(f"🚀 Render SOCKS5 Bridge running on socks5://{LOCAL_HOST}:{LOCAL_PORT}")
    logging.info(f"Dynamically targeting: {RENDER_TS_HOST}:{RENDER_TS_PORT} via Tailscale")
    logging.info("UDP NAT Keep-Alive daemon active (20s cycle)")
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
