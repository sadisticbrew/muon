#!/usr/bin/env python3
"""Unix-socket connect flood for the Muon benchmark (bench/conn_flood.py).

Usage:
    conn_flood.py server [N]       # listen; exit after N accepts (default: forever)
    conn_flood.py client <N>        # make N sequential connects, then exit

Unix domain sockets: no port exhaustion, no TIME_WAIT backlog, ~microseconds
per connect. Every connect fires sys_enter_connect (the probe under test);
socket()/accept()/close() are untraced, so the stream is pure connects.
"""
import os
import socket
import sys

SOCK_PATH = "/tmp/muon_conn_test.sock"


def server(limit=None):
    try:
        os.unlink(SOCK_PATH)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    srv.listen(256)
    served = 0
    while limit is None or served < limit:
        conn, _ = srv.accept()
        conn.close()
        served += 1


def client(count):
    for _ in range(count):
        cli = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        cli.connect(SOCK_PATH)
        cli.close()


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("server", "client"):
        sys.exit("usage: conn_flood.py server|client [N]")
    if sys.argv[1] == "server":
        server(int(sys.argv[2]) if len(sys.argv) > 2 else None)
    else:
        client(int(sys.argv[2]) if len(sys.argv) > 2 else 1000)
