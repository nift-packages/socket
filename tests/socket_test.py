#!/usr/bin/env python3
"""Self-contained socket package contract. Exercises the package's own
listener+client over the real loopback interface on the current platform. No
public network, no Python fixture server (both endpoints come from the
package). Python is used only by this harness; the production package is pure
Nift FFI.
"""
import os
import shutil
import subprocess
import sys
import tempfile

NIFT = sys.argv[1] if len(sys.argv) > 1 else "nift"
PKG = sys.argv[2] if len(sys.argv) > 2 else "."

work = tempfile.mkdtemp(prefix="socket-test-")
os.makedirs(os.path.join(work, ".nift"), exist_ok=True)
subprocess.run([NIFT, "add", PKG], cwd=work, check=True, capture_output=True)

failures = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'} {name}")
    if not cond:
        failures.append(name)
        if detail:
            print("  " + detail.replace("\n", "\n  "))


def run(name, script, timeout=30):
    path = os.path.join(work, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write('@import("socket")\n' + script + "\n")
    out = subprocess.run([NIFT, name], cwd=work, capture_output=True, text=True, encoding="utf-8", timeout=timeout)
    return out


# ---- basic listener/client + bidirectional exchange -------------------------
out = run("t1.f", """
l := socket.listen({"host": "127.0.0.1", "port": 0})
print(l.ok)
print(l.port > 0)
print(l.handle.kind)
c := socket.connect({"host": "127.0.0.1", "port": l.port})
print(c.ok)
a := socket.accept(l.handle)
print(a.ok)
print(socket.send_all(c.conn, "hello").ok)
r := socket.recv(a.conn, 64)
print(r.ok)
print(r.eof)
print(r.data.decode("utf-8"))
print(socket.send_all(a.conn, "world").ok)
r2 := socket.recv(c.conn, 64)
print(r2.data.decode("utf-8"))
socket.close(c.conn)
socket.close(a.conn)
socket.close(l.handle)
""")
lines = out.stdout.strip().splitlines()
check("basic listener/client exchange", lines == ["true", "true", "listener", "true", "true", "true", "true",
                                                 "false", "hello", "true", "world"], out.stdout + out.stderr)

# ---- binary roundtrip --------------------------------------------------------
out = run("t2.f", """
l := socket.listen({"host": "127.0.0.1", "port": 0})
c := socket.connect({"host": "127.0.0.1", "port": l.port})
a := socket.accept(l.handle)
payload := bytes([0, 255, 10, 13, 65, 66, 128, 254])
print(socket.send_all(c.conn, payload).ok)
r := socket.recv(a.conn, 64)
big := []
bi := 0
while(bi < 16384) { big.push(bi % 256); bi += 1 }
bigb := bytes(big)
print(socket.send_all(c.conn, bigb).ok)
rb := socket.recv(a.conn, 65536)
print(rb.ok)
print(rb.data.length())
print(r.ok)
print(r.data.length())
print(r.data[0])
print(r.data[1])
print(r.data[7])
socket.close(c.conn)
socket.close(a.conn)
socket.close(l.handle)
""")
lines = out.stdout.strip().splitlines()
check("binary roundtrip exact", len(lines) == 9 and lines[0] == "true" and lines[1] == "true"
      and lines[2] == "true" and lines[3] == "16384" and lines[4] == "true" and lines[5] == "8"
      and lines[6] == "0" and lines[7] == "255" and lines[8] == "254", out.stdout + out.stderr)

# ---- local/peer address ------------------------------------------------------
out = run("t3.f", """
l := socket.listen({"host": "127.0.0.1", "port": 0})
c := socket.connect({"host": "127.0.0.1", "port": l.port})
a := socket.accept(l.handle)
la := socket.local_address(l.handle)
print(la.host)
print(la.port == l.port)
pa := socket.peer_address(c.conn)
print(pa.host)
print(pa.port == l.port)
socket.close(c.conn)
socket.close(a.conn)
socket.close(l.handle)
""")
lines = out.stdout.strip().splitlines()
check("local/peer address", len(lines) == 4 and lines[0] == "127.0.0.1" and lines[1] == "true"
      and lines[2] == "127.0.0.1" and lines[3] == "true", out.stdout + out.stderr)

# ---- non-blocking would_block -----------------------------------------------
out = run("t4.f", """
l := socket.listen({"host": "127.0.0.1", "port": 0})
c := socket.connect({"host": "127.0.0.1", "port": l.port})
a := socket.accept(l.handle)
r := socket.recv(a.conn, 64)
print(r.ok)
print(r.would_block)
print(r.error_code)
socket.close(c.conn)
socket.close(a.conn)
socket.close(l.handle)
""")
lines = out.stdout.strip().splitlines()
check("non-blocking recv would_block", lines == ["false", "true", "would_block"], out.stdout + out.stderr)

# ---- poll readiness ---------------------------------------------------------
out = run("t5.f", """
l := socket.listen({"host": "127.0.0.1", "port": 0})
p0 := socket.poll([l.handle], 0)
print(p0.ok)
print(p0.results.size())
print(p0.error)
c := socket.connect({"host": "127.0.0.1", "port": l.port})
print("l_ok=" + socket.local_address(l.handle).ok.to_string())
l2 := socket.listen({"host": "127.0.0.1", "port": 0})
p2b := socket.poll([l2.handle], 0)
print("l2=" + p2b.ok.to_string() + ":" + p2b.error + ":" + p2b.results[0].readable.to_string())
p1 := socket.poll([l.handle], 0)
print(p1.results[0].readable)
a := socket.accept(l.handle)
socket.send_all(c.conn, "data")
p2 := socket.poll([a.conn], 0)
print(p2.results[0].readable)
print(socket.recv(a.conn, 64).data.decode("utf-8"))
socket.close(c.conn)
socket.close(a.conn)
socket.close(l.handle)
""")
lines = out.stdout.strip().splitlines()
check("poll readiness", len(lines) == 8 and lines[0] == "true" and lines[1] == "1" and lines[2] == ""
      and lines[3] == "l_ok=true" and lines[4] == "l2=true::false" and lines[5] == "true"
      and lines[6] == "true" and lines[7] == "data", out.stdout + out.stderr)

# ---- EOF --------------------------------------------------------------------
out = run("t6.f", """
l := socket.listen({"host": "127.0.0.1", "port": 0})
c := socket.connect({"host": "127.0.0.1", "port": l.port})
a := socket.accept(l.handle)
socket.close(c.conn)
r := socket.recv(a.conn, 64)
print(r.ok)
print(r.eof)
socket.close(a.conn)
socket.close(l.handle)
""")
lines = out.stdout.strip().splitlines()
check("EOF distinguished", lines == ["true", "true"], out.stdout + out.stderr)

# ---- invalid handles + lifecycle --------------------------------------------
out = run("t7.f", """
l := socket.listen({"host": "127.0.0.1", "port": 0})
c := socket.connect({"host": "127.0.0.1", "port": l.port})
a := socket.accept(l.handle)
print(socket.close(a.conn).ok)
print(socket.recv(a.conn, 16).error_code)
print(socket.send(a.conn, "x").error_code)
print(socket.close(a.conn).error_code)
print(socket.send(c.conn, "y").ok)
socket.close(c.conn)
socket.close(l.handle)
print(socket.recv(l.handle, 16).error_code)
""")
lines = out.stdout.strip().splitlines()
check("invalid handles + double close", lines == ["true", "invalid_handle", "invalid_handle", "invalid_handle",
                                                 "true", "invalid_handle"], out.stdout + out.stderr)

# ---- repeated open/close stress ---------------------------------------------
out = run("t8.f", """
i := 0
good := 0
while(i < 40) {
    l := socket.listen({"host": "127.0.0.1", "port": 0})
    c := socket.connect({"host": "127.0.0.1", "port": l.port})
    a := socket.accept(l.handle)
    socket.send_all(c.conn, "ping")
    p := socket.poll([a.conn], 1000)
    r := socket.recv(a.conn, 16)
    if(!r.ok && r.would_block) {
        p2 := socket.poll([a.conn], 1000)
        r2 := socket.recv(a.conn, 16)
        r = r2
    }
    if(r.ok && r.data.length() == 4 && r.data[0] == 112 && r.data[1] == 105 && r.data[2] == 110 && r.data[3] == 103) { good += 1 }
    socket.close(c.conn)
    socket.close(a.conn)
    socket.close(l.handle)
    i += 1
}
print(good)
""")
lines = out.stdout.strip().splitlines()
check("repeated open/close stress", lines == ["40"], out.stdout + out.stderr)

# ---- explicit port + bind conflict ------------------------------------------
out = run("t9.f", """
import_socket := socket
l := socket.listen({"host": "127.0.0.1", "port": 0})
l2 := socket.listen({"host": "127.0.0.1", "port": l.port})
print(l2.ok)
print(l2.error_code)
socket.close(l.handle)
l3 := socket.listen({"host": "127.0.0.1", "port": l.port})
print(l3.ok)
socket.close(l3.handle)
bad := socket.listen({"host": "999.1.1.1", "port": 0})
print(bad.error_code)
""")
lines = out.stdout.strip().splitlines()
check("bind conflict + invalid host", lines == ["false", "address_in_use", "true", "invalid_address"],
      out.stdout + out.stderr)

# ---- connect refused --------------------------------------------------------
out = run("t10.f", """
c := socket.connect({"host": "127.0.0.1", "port": 1})
print(c.ok)
print(c.error_code)
""")
lines = out.stdout.strip().splitlines()
check("connect refused", lines == ["false", "connection_refused"], out.stdout + out.stderr)

if failures:
    print("FAILED:", ", ".join(failures))
    sys.exit(1)
print("PASS socket contract")