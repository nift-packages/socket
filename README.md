# socket

Cross-platform TCP sockets for Nift, implemented entirely over the existing
Nift FFI (`libc` / `libSystem` / `ws2_32`). No Nift core change, no Python, no
C shim. This is the transport foundation for the Python-free HTTP server
(SERVER1 of the server campaign); it is also independently usable.

## Status

- **Supported platforms:** Linux, macOS, Windows **x64** (Winsock). 32-bit
  Windows is not certified.
- **IPv4 only.** IPv6 (`sockaddr_in6`) and DNS hostname resolution are not yet
  implemented; hosts must be numeric IPv4 (`"127.0.0.1"`, `"192.168.1.5"`).
- **TCP only.** No UDP, no TLS. Do not claim TLS or UDP.
- **Non-blocking by default.** Every listener/connection handle is created
  non-blocking and is consumed through the `poll` event-loop model.
- **`connect` is a blocking call** (the only one): it completes the TCP
  handshake synchronously and can block until the peer accepts or the OS
  connect timeout. This is acceptable for SERVER1 because the server side
  (listen/accept/recv/send) never calls connect; a future non-blocking connect
  can resolve completion via poll writability + `getpeername`/`SO_ERROR`.
- **Binary-safe.** `recv` returns a Nift `bytes` value; embedded NUL, `0xff`
  and multibyte bytes round-trip exactly. Network payloads never use
  NUL-terminated or text semantics.

## API

```text
listener := socket.listen({"host": "127.0.0.1", "port": 0})
conn := socket.connect({"host": "127.0.0.1", "port": listener.port})
accepted := socket.accept(listener)

r := socket.recv(conn, 4096)        // {ok, data, eof, would_block, error_code, error}
socket.send(conn, data)             // {ok, sent, would_block, ...}; partial sends
socket.send_all(conn, data)         // loops partial sends; {ok, sent, would_block, ...}

socket.poll([listener, conn], timeout_ms)   // [{handle, readable, writable, error, hangup}]
                                              // writable is reported (POLLIN|POLLOUT)
socket.local_address(handle)        // {ok, host, port}
socket.peer_address(handle)
socket.shutdown(conn)
socket.close(handle)
```

Handles are plain transferable data maps (`{kind, fd, _id}`), not struct
facades, so they can cross worker boundaries in a later event loop.

`recv` result contract:

```text
ok: true,  data: bytes, eof: false      // read of max bytes (or fewer)
ok: true,  data: bytes(), eof: true      // peer closed (0-byte read)
ok: false, would_block: true             // nothing available right now
ok: false, error_code: connection_reset / invalid_handle / ...
```

## Error model

POSIX `errno` is not directly readable through Nift FFI, so the package emits
stable outcomes instead of raw errno:

```text
address_in_use, connection_refused, connection_reset, would_block,
invalid_address, invalid_handle, socket_error
```

On Windows, `WSAGetLastError()` is consulted internally (`WSAEWOULDBLOCK`
→ `would_block`). On POSIX, `would_block` is classified with a zero-timeout
`poll` heuristic when a non-blocking read/write has nothing pending.

## Poll layout

`poll()` uses the platform-native readiness primitive. On POSIX it builds the
native `struct pollfd` (`int fd` / `short events` / `short revents`, 8 bytes on
LP64). On Windows it uses Winsock `select()` over a manually-built `fd_set`
(fd_count + 8-byte `SOCKET` array) rather than `WSAPoll`, and `socket.poll` is
limited to 64 handles per call on Windows (FD_SETSIZE).

## Lifecycle

- `socket.close(handle)` closes the native descriptor and deregisters the
  handle; a second close (or any use of a closed handle) returns
  `invalid_handle`.
- On Windows, `WSAStartup` runs once at first use (process-lifetime
  initialization) and `WSACleanup` is never called, so no cleanup race can
  close live sockets. `closesocket` (not C runtime `close`) is used.
- Bind failures, connect failures and early returns close the native
  descriptor before returning.

## Known limitations

- POSIX `errno` values are not surfaced (see error model); some errors collapse
  to `socket_error`.
- DNS hostnames are not resolved; hosts must be numeric IPv4.
- IPv6 is not implemented.

## Top-level wrappers (cross-package use)

Struct facades from one package are not reachable inside another package's
functions in Nift, so the socket package also exports self-contained top-level
functions that any package can import and call:

```text
sock_listen(opts) / sock_accept(listener) / sock_connect(opts)
sock_recv(conn, max) / sock_send(conn, data) / sock_send_all(conn, data)
sock_shutdown(conn) / sock_close(handle)
sock_local_address(handle) / sock_peer_address(handle)
sock_poll(items, timeout_ms) / sock_available()
```

These are the cross-package transport API (the `socket` facade remains for
in-script use); e.g. the `http` package native backend uses `sock_*`.

## Tests

`tests/socket_test.py` (self-contained, loopback only, no public network) runs
listener/client basics, binary roundtrip, addresses, non-blocking `would_block`,
`poll` readiness, EOF, invalid handles / double close, bind conflict, connect
refused, and a 40-iteration open/close stress loop. Python is used by the test
harness only; the production package is pure Nift FFI.