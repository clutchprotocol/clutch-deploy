#!/usr/bin/env python3
"""One JSON-RPC call against a clutch-node, over WebSocket, using only the stdlib.

The nodes speak WebSocket JSON-RPC and nothing else, so curl returns nothing at all against
8081-8083 -- which has misled this project more than once. `websocat` is not on the VPS and pulling
an image to ask one question is worse. This is the smallest thing that can ask.

    python3 node-rpc.py ws://node1:8081/ws get_account_balance '{"address":"0x..."}'

ponytail: no ping/pong, no continuation frames, no TLS. One request, one reply, on a plain-ws
in-network port. Reach for a real client if any of that stops being true.
"""
import base64, json, os, socket, struct, sys
from urllib.parse import urlparse


def recv_exactly(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise RuntimeError("connection closed mid-frame")
        buf += chunk
    return buf


def read_frame(sock):
    b1, b2 = recv_exactly(sock, 2)
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", recv_exactly(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exactly(sock, 8))[0]
    # Server frames are never masked.
    return b1 & 0x0F, recv_exactly(sock, length)


def main():
    url, method, params = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "{}"
    u = urlparse(url)
    port = u.port or 80
    sock = socket.create_connection((u.hostname, port), timeout=15)

    key = base64.b64encode(os.urandom(16)).decode()
    path = u.path or "/"
    sock.sendall(
        f"GET {path} HTTP/1.1\r\nHost: {u.hostname}:{port}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        .encode()
    )
    handshake = b""
    while b"\r\n\r\n" not in handshake:
        handshake += sock.recv(4096)
    if b"101" not in handshake.split(b"\r\n")[0]:
        print(f"handshake refused: {handshake.split(chr(13).encode())[0].decode(errors='replace')}")
        sys.exit(1)

    payload = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": json.loads(params)}
    ).encode()
    # Client frames MUST be masked (RFC 6455); an unmasked one is dropped without explanation.
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    header = b"\x81"
    n = len(payload)
    if n < 126:
        header += bytes([0x80 | n])
    elif n < 1 << 16:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    sock.sendall(header + mask + masked)

    while True:
        opcode, data = read_frame(sock)
        if opcode == 0x8:
            print("closed by server before replying")
            sys.exit(1)
        if opcode in (0x1, 0x2):
            print(data.decode(errors="replace"))
            return


if __name__ == "__main__":
    main()
