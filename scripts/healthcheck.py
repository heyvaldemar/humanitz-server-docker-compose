"""healthcheck.py - healthy only when the game itself answers.

Run by Docker inside the server's container (the compose file mounts it
read-only). It logs in to the game's RCON on 127.0.0.1, asks `info`, and
exits 0 only when the reply carries the game's "N connected." line. Only the
running game writes that line.

NOT THE PROCESS. Up to v1.1.6 the check looked for HumanitZServer in /proc.
A hung or stopped game keeps its process, and the check stayed green over it;
tests/e2e-game.sh stops the game with SIGSTOP and requires this one to go red.

NOT THE LOG. A server with nobody on it writes nothing for hours.

WITHIN DOCKER'S TIMEOUT. Every connect and read shares one deadline of
8 seconds, inside the 10 Docker gives the check.

THE PASSWORD comes from the container's own environment, where compose put
it (HUMANITZ_RCON_PASSWORD), and is never printed. RCON is published nowhere,
so this is the only way in from outside the game.

INSIDE THE CONTAINER. Healthy proves the game answers here. It does not prove
the game port is published on the host, nor that a firewall lets players in.

HumanitZ's RCON, as scripts/rcon.py describes it: the login answers with an
empty RESPONSE_VALUE first, then the AUTH_RESPONSE; replies end lines with
CRLF; an unknown command gets no reply at all.
"""
import os
import re
import socket
import struct
import sys
import time

DEADLINE = time.monotonic() + 8


def left():
    remaining = DEADLINE - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("no answer within 8 seconds")
    return remaining


def packet(request_id, kind, body):
    payload = body.encode() + b"\x00\x00"
    return struct.pack("<iii", len(payload) + 8, request_id, kind) + payload


def take(sock, n):
    data = b""
    while len(data) < n:
        sock.settimeout(left())
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("the game closed the connection")
        data += chunk
    return data


def read(sock):
    (size,) = struct.unpack("<i", take(sock, 4))
    data = take(sock, size)
    request_id, kind = struct.unpack("<ii", data[:8])
    return request_id, kind, data[8:-2].decode("utf-8", "replace").replace("\r", "")


def main():
    password = os.environ.get("HUMANITZ_RCON_PASSWORD", "")
    port = int(os.environ.get("RCON_PORT", "8888"))
    if not password:
        print("unhealthy: HUMANITZ_RCON_PASSWORD is not set in the container", file=sys.stderr)
        return 1
    body = ""
    try:
        sock = socket.create_connection(("127.0.0.1", port), left())
        sock.sendall(packet(1, 3, password))
        while True:
            request_id, kind, _ = read(sock)
            if kind == 2:
                break
        if request_id == -1:
            print("unhealthy: the game refused the RCON password", file=sys.stderr)
            return 1
        # Whatever id the reply carries: scripts/rcon.py does not match it
        # either, and the reply is read until the line shows or time is up.
        sock.sendall(packet(10, 2, "info"))
        body = ""
        found = None
        while not found:
            body += read(sock)[2] + "\n"
            found = re.search(r"^(\d+) connected\.", body, re.M)
    except (OSError, ConnectionError, TimeoutError, struct.error) as error:
        if body.strip():
            print("unhealthy: the game answered info without its 'connected.' line", file=sys.stderr)
        else:
            print("unhealthy: no RCON answer on 127.0.0.1:%d (%s)" % (port, error), file=sys.stderr)
        return 1
    print("healthy: the game answered RCON info (%s connected)" % found.group(1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
