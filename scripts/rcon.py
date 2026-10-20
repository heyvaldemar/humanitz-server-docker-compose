# rcon.py: a Source RCON client for the HumanitZ server, run INSIDE the
# server's container by scripts/rcon.sh (`docker exec -i ... python3 - < this`).
#
# INSIDE, because the RCON port is published nowhere: nothing outside the
# container can reach it, so the password is not the only lock on it.
#
# The password comes from the container's own environment, where compose put
# it (HUMANITZ_RCON_PASSWORD), never from argv, which every process on the
# host can read. RCON_PASSWORD overrides it, for tests.
#
# HumanitZ's RCON, as measured on the server this template comes from:
#   - authentication answers with an empty RESPONSE_VALUE first, then the
#     AUTH_RESPONSE;
#   - an unknown command gets no reply at all, so every read has a timeout and
#     "no reply" is reported, not waited on;
#   - replies end lines with CRLF. Kept, the \r breaks anything that parses the
#     reply (a status page once read a healthy server as offline over it), so
#     it is removed here, once, for every caller.
import os
import socket
import struct
import sys


def packet(request_id, kind, body):
    payload = body.encode() + b"\x00\x00"
    return struct.pack("<iii", len(payload) + 8, request_id, kind) + payload


def read(sock):
    head = b""
    while len(head) < 4:
        chunk = sock.recv(4 - len(head))
        if not chunk:
            raise ConnectionError("closed")
        head += chunk
    (size,) = struct.unpack("<i", head)
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    request_id, kind = struct.unpack("<ii", data[:8])
    return request_id, kind, data[8:-2].decode("utf-8", "replace").replace("\r", "")


def report_status(password, port):
    """--status: one line of JSON. "Unknown" with players null when RCON does
    not answer, never "Online" with 0: a dead probe must not claim an empty
    server."""
    import json
    import re
    import time
    info = ""
    for _ in range(3):
        try:
            sock = socket.create_connection(("127.0.0.1", port), 5)
            sock.settimeout(5)
            sock.sendall(packet(1, 3, password))
            request_id, kind, _ = read(sock)
            if kind != 2:
                request_id, kind, _ = read(sock)
            if request_id == 1:
                sock.sendall(packet(10, 2, "info"))
                info = read(sock)[2]
                break
        except (OSError, ConnectionError):
            time.sleep(2)
    found = re.search(r"^(\d+) connected\.", info, re.M)
    season = re.search(r"^Season: (.+)$", info, re.M)
    slots = None
    try:
        settings = os.environ.get("HUMANITZ_SETTINGS", "/data/serverfiles/HumanitZServer/GameServerSettings.ini")
        for line in open(settings, encoding="utf-8", errors="replace"):
            if line.startswith("MaxPlayers="):
                slots = int(line.split("=", 1)[1].strip())
                break
    except (OSError, ValueError):
        pass
    print(json.dumps({"status": "Online" if found else "Unknown",
                      "players": int(found.group(1)) if found else None,
                      "max": slots,
                      "season": season.group(1).strip() if season else None,
                      "checked": int(time.time())}))
    return 0 if found else 1


def main():
    password = os.environ.get("RCON_PASSWORD") or os.environ.get("HUMANITZ_RCON_PASSWORD", "")
    port = int(os.environ.get("RCON_PORT", "8888"))
    commands = sys.argv[1:]
    if commands == ["--status"] and password:
        return report_status(password, port)
    if not password or not commands:
        print("usage: python3 rcon.py <command> [command ...], with HUMANITZ_RCON_PASSWORD set", file=sys.stderr)
        return 2
    try:
        sock = socket.create_connection(("127.0.0.1", port), 5)
    except OSError as error:
        print("RCON unreachable: %s" % error, file=sys.stderr)
        return 3
    sock.settimeout(5)
    try:
        sock.sendall(packet(1, 3, password))
        request_id, kind, _ = read(sock)
        if kind != 2:
            request_id, kind, _ = read(sock)
    except (OSError, ConnectionError) as error:
        print("RCON authentication got no answer: %s" % error, file=sys.stderr)
        return 4
    if request_id != 1:
        print("RCON authentication failed", file=sys.stderr)
        return 4
    status = 0
    for number, command in enumerate(commands, start=10):
        sock.sendall(packet(number, 2, command))
        try:
            print(read(sock)[2])
        except socket.timeout:
            print("no reply to %r" % command, file=sys.stderr)
            status = 5
    return status


sys.exit(main())
