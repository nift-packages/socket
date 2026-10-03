/*
    socket package for Nift. Cross-platform TCP sockets over the existing Nift
    FFI (libc / libSystem / ws2_32). No Nift core change, no Python, no C shim.

    Handles are plain transferable data maps ({"kind","fd","_id"}), not struct
    facades, so they can cross worker boundaries later. All handles are created
    non-blocking. Windows is qualified on x64 (Winsock, SOCKET is 8 bytes);
    32-bit Windows is not certified.

    Known limitation: POSIX errno is not directly readable through Nift FFI, so
    would_block on POSIX is classified with a zero-timeout poll heuristic and
    other errors are stable package codes.
*/

socket_lib := ""
socket_inited := false
socket_init_ok := true
socket_seq := 0
socket_open := map()


fn(s_lib()) {
    if(socket_lib == "") {
        if(os() == "windows") { socket_lib = ffi_open("ws2_32.dll") }
        else if(os() == "macos") { socket_lib = ffi_open("libSystem.B.dylib") }
        else { socket_lib = ffi_open("libc.so.6") }
    }
    return socket_lib
}
fn(s_ensure_init()) {
    if(os() == "windows" && !socket_inited) {
        wsa := ffi_buffer(s_zeros(512))
        rc := ffi_call(s_lib(), "WSAStartup", "i32(i32,buffer)", 514, wsa)
        socket_inited = true
        if(rc != 0) { socket_init_ok = false }
    }
    return null
}
fn(s_zeros(n)) {
    a := []
    i := 0
    while(i < n) { a.push(0); i += 1 }
    return bytes(a)
}
fn(s_le32(v)) {
    b0 := v % 256
    r1 := ((v - b0) / 256).to_int()
    b1 := r1 % 256
    r2 := ((r1 - b1) / 256).to_int()
    b2 := r2 % 256
    b3 := ((r2 - b2) / 256).to_int()
    return [b0, b1, b2, b3]
}
fn(s_le64(v)) {
    lo := s_le32(v)
    hi := s_le32(((v - (lo[0] + lo[1] * 256 + lo[2] * 65536 + lo[3] * 16777216)) / 4294967296).to_int())
    return [lo[0], lo[1], lo[2], lo[3], hi[0], hi[1], hi[2], hi[3]]
}
fn(s_high16(port)) {
    return ((port - (port % 256)) / 256).to_int()
}
fn(s_is_digits(s)) {
    if(s == "") { return false }
    i := 0
    while(i < s.length()) {
        c := s.substr(i, 1)
        if(c < "0" || c > "9") { return false }
        i += 1
    }
    return true
}
fn(s_ipv4(host)) {
    if(type(host) != "string") { return null }
    parts := host.split(".")
    if(parts.size() != 4) { return null }
    out := []
    i := 0
    valid := true
    while(i < 4 && valid) {
        p := parts[i]
        if(p == "" || !s_is_digits(p)) { valid = false }
        else {
            v := p.to_int()
            if(v > 255) { valid = false }
            else { out.push(v) }
        }
        i += 1
    }
    if(!valid) { return null }
    return out
}
fn(s_sockaddr4(host, port)) {
    a := s_ipv4(host)
    if(a == null) { return null }
    return bytes([2, 0, s_high16(port), port % 256, a[0], a[1], a[2], a[3], 0, 0, 0, 0, 0, 0, 0, 0])
}
fn(s_handle(kind, fd)) {
    socket_seq += 1
    id := socket_seq
    socket_open.set(id, "1")
    return {"kind":kind,"fd":fd,"_id":id}
}
fn(s_valid(h)) {
    if(type(h) != "object" || !h.has("kind") || !h.has("fd") || !h.has("_id")) { return false }
    return socket_open.contains(h._id)
}
fn(s_close_native(fd)) {
    if(os() == "windows") { ffi_call(s_lib(), "closesocket", "i32(i64)", fd) }
    else { ffi_call(s_lib(), "close", "i32(i64)", fd) }
    return null
}
fn(s_nonblock_native(fd)) {
    if(os() == "windows") {
        one := ffi_buffer(bytes([1, 0, 0, 0]))
        ffi_call(s_lib(), "ioctlsocket", "i32(i64,i64,buffer)", fd, 2147772030, one)
    } else {
        fl := ffi_call(s_lib(), "fcntl", "i32(i64,i32)", fd, 3)
        nb := 2048
        if(os() == "macos") { nb = 4 }
        ffi_call(s_lib(), "fcntl", "i32(i64,i32,i64)", fd, 4, fl + nb)
    }
    return null
}
fn(s_addr_result(name_bytes)) {
    b := ffi_bytes(name_bytes)
    port := b[2].to_int() * 256 + b[3].to_int()
    host := b[4].to_int().to_string() + "." + b[5].to_int().to_string() + "." + b[6].to_int().to_string() + "." + b[7].to_int().to_string()
    return {"ok":true,"host":host,"port":port,"error":"","error_code":""}
}
fn(s_address_query(handle, peer)) {
    if(!s_valid(handle)) {
        return {"ok":false,"host":"","port":0,"error":"invalid socket handle","error_code":"invalid_handle"}
    }
    saddr := ffi_buffer(s_zeros(16))
    slen := ffi_buffer(bytes([16, 0, 0, 0, 0, 0, 0, 0]))
    sym := "getsockname"
    if(peer) { sym = "getpeername" }
    rc := ffi_call(s_lib(), sym, "i32(i64,buffer,buffer)", handle.fd, saddr, slen)
    if(rc != 0) { return {"ok":false,"host":"","port":0,"error":"address query failed","error_code":"socket_error"} }
    return s_addr_result(saddr)
}
fn(s_native_err()) {
    if(os() == "windows") { return ffi_call(s_lib(), "WSAGetLastError", "i32()") }
    return 0
}
fn(s_winsock_fdset_bytes(fd)) {
    arr := []
    arr.push(1); arr.push(0); arr.push(0); arr.push(0)
    arr.push(0); arr.push(0); arr.push(0); arr.push(0)
    le := s_le64(fd)
    arr.push(le[0]); arr.push(le[1]); arr.push(le[2]); arr.push(le[3])
    arr.push(le[4]); arr.push(le[5]); arr.push(le[6]); arr.push(le[7])
    i := 0
    while(i < 504) { arr.push(0); i += 1 }
    return bytes(arr)
}
fn(s_timeval_bytes(timeout)) {
    sec := ((timeout - (timeout % 1000)) / 1000).to_int()
    usec := (timeout - sec * 1000) * 1000
    sb := s_le32(sec)
    ub := s_le32(usec)
    return bytes([sb[0], sb[1], sb[2], sb[3], ub[0], ub[1], ub[2], ub[3]])
}
fn(s_winsock_ready(fd, timeout, events)) {
    rd := ffi_buffer(s_zeros(520))
    wr := ffi_buffer(s_zeros(520))
    ex := ffi_buffer(s_zeros(520))
    if(s_bit(events, 1)) { rd = ffi_buffer(s_winsock_fdset_bytes(fd)) }
    if(s_bit(events, 4)) { wr = ffi_buffer(s_winsock_fdset_bytes(fd)) }
    tv := ffi_buffer(s_timeval_bytes(timeout))
    rc := ffi_call(s_lib(), "select", "i32(i32,buffer,buffer,buffer,buffer)", 0, rd, wr, ex, tv)
    if(rc < 0) { return {"readable":false,"writable":false,"error":true,"hangup":false} }
    rdg := ffi_bytes(rd)
    wrg := ffi_bytes(wr)
    readable := rdg[0].to_int() + rdg[1].to_int() * 256 > 0
    writable := wrg[0].to_int() + wrg[1].to_int() * 256 > 0
    return {"readable":readable,"writable":writable,"error":false,"hangup":false}
}
fn(s_winsock_poll(items, timeout_ms)) {
    n := items.size()
    if(n > 64) {
        return {"ok":false,"results":[],"error":"socket.poll supports at most 64 handles on Windows","error_code":"invalid_argument"}
    }
    ra := []
    ra.push(n % 256); ra.push(((n - (n % 256)) / 256).to_int() % 256); ra.push(0); ra.push(0)
    ra.push(0); ra.push(0); ra.push(0); ra.push(0)
    wa := []
    wa.push(n % 256); wa.push(((n - (n % 256)) / 256).to_int() % 256); wa.push(0); wa.push(0)
    wa.push(0); wa.push(0); wa.push(0); wa.push(0)
    for(it : items) {
        le := s_le64(it.fd)
        ra.push(le[0]); ra.push(le[1]); ra.push(le[2]); ra.push(le[3])
        ra.push(le[4]); ra.push(le[5]); ra.push(le[6]); ra.push(le[7])
        wa.push(le[0]); wa.push(le[1]); wa.push(le[2]); wa.push(le[3])
        wa.push(le[4]); wa.push(le[5]); wa.push(le[6]); wa.push(le[7])
    }
    i := 0
    while(i < 520 - 8 - n * 8) { ra.push(0); wa.push(0); i += 1 }
    rd := ffi_buffer(bytes(ra))
    wr := ffi_buffer(bytes(wa))
    ex := ffi_buffer(s_zeros(520))
    tv := ffi_buffer(s_timeval_bytes(timeout_ms))
    rc := ffi_call(s_lib(), "select", "i32(i32,buffer,buffer,buffer,buffer)", 0, rd, wr, ex, tv)
    if(rc < 0) {
        em := "poll failed (native " + s_native_err().to_string() + ")"
        return {"ok":false,"results":[],"error":em,"error_code":"socket_error"}
    }
    rset := s_compacted_fds(rd)
    wset := s_compacted_fds(wr)
    results := []
    for(it : items) {
        readable := false
        writable := false
        for(r : rset) { if(r == it.fd) { readable = true } }
        for(w : wset) { if(w == it.fd) { writable = true } }
        results.push({"handle":it,"readable":readable,"writable":writable,"error":false,"hangup":false})
    }
    return {"ok":true,"results":results,"error":"","error_code":""}
}
fn(s_compacted_fds(buf)) {
    got := ffi_bytes(buf)
    cnt := got[0].to_int() + got[1].to_int() * 256 + got[2].to_int() * 65536 + got[3].to_int() * 16777216
    out := []
    j := 0
    while(j < cnt) {
        base := 8 + j * 8
        fv := got[base].to_int() + got[base + 1].to_int() * 256 + got[base + 2].to_int() * 65536 + got[base + 3].to_int() * 16777216
        out.push(fv)
        j += 1
    }
    return out
}
fn(s_pollfd_result(fd, timeout, events)) {
    if(os() == "windows") { return s_winsock_ready(fd, timeout, events) }
    seq := []
    ev := s_le32(events)
    le := s_le32(fd)
    if(os() == "windows") {
        seq.push(le[0]); seq.push(le[1]); seq.push(le[2]); seq.push(le[3])
        seq.push(0); seq.push(0); seq.push(0); seq.push(0)
        seq.push(ev[0]); seq.push(ev[1])
        seq.push(0); seq.push(0)
        seq.push(0); seq.push(0); seq.push(0); seq.push(0)
    } else {
        seq.push(le[0]); seq.push(le[1]); seq.push(le[2]); seq.push(le[3])
        seq.push(ev[0]); seq.push(ev[1])
        seq.push(0); seq.push(0)
    }
    pf := ffi_buffer(bytes(seq))
    rc := ffi_call(s_lib(), "poll", "i32(buffer,i64,i32)", pf, 1, timeout)
    if(rc < 0) { return {"readable":false,"writable":false,"error":true,"hangup":false} }
    got := ffi_bytes(pf)
    rv := got[6].to_int() + got[7].to_int() * 256
    return {"readable":s_bit(rv,1),"writable":s_bit(rv,4),"error":s_bit(rv,8),"hangup":s_bit(rv,16)}
}
fn(s_would_block_now(fd)) {
    pr := s_pollfd_result(fd, 0, 1)
    return !pr.readable && !pr.writable && !pr.error && !pr.hangup
}
fn(s_payload_bytes(data)) {
    if(type(data) == "string") { return data.encode("utf-8") }
    return data
}
fn(s_bit(v, place)) {
    return ((v - (v % place)) / place).to_int() % 2 == 1
}
fn(s_bytes_slice(b, start, count)) {
    out := []
    i := start
    stop := start + count
    if(stop > b.length()) { stop = b.length() }
    while(i < stop) { out.push(b[i]); i += 1 }
    return bytes(out)
}
fn(s_send_payload(conn, payload)) {
    if(!s_valid(conn) || conn.kind != "conn") {
        return {"ok":false,"sent":0,"would_block":false,"error":"invalid socket handle","error_code":"invalid_handle"}
    }
    total := payload.length()
    if(total == 0) { return {"ok":true,"sent":0,"would_block":false,"error":"","error_code":""} }
    pr := s_pollfd_result(conn.fd, 0, 4)
    if(!pr.writable && !pr.error && !pr.hangup) {
        return {"ok":false,"sent":0,"would_block":true,"error":"","error_code":"would_block"}
    }
    sig := "i64(i64,buffer,i64,i32)"
    if(os() == "windows") { sig = "i32(i64,buffer,i64,i32)" }
    buf := ffi_buffer(payload)
    rc := ffi_call(s_lib(), "send", sig, conn.fd, buf, total, 0)
    if(rc < 0) {
        if(os() == "windows") {
            e := s_native_err()
            if(e == 10035) { return {"ok":false,"sent":0,"would_block":true,"error":"","error_code":"would_block"} }
            return {"ok":false,"sent":0,"would_block":false,"error":"send failed","error_code":"connection_reset"}
        }
        if(s_would_block_now(conn.fd)) {
            return {"ok":false,"sent":0,"would_block":true,"error":"","error_code":"would_block"}
        }
        return {"ok":false,"sent":0,"would_block":false,"error":"send failed","error_code":"connection_reset"}
    }
    return {"ok":true,"sent":rc,"would_block":false,"error":"","error_code":""}
}
fn(sock_listen(opts)) {
    s_ensure_init()
    l := s_lib()
    host := "127.0.0.1"
    port := 0
    backlog := 16
    if(type(opts) == "object") {
        if(opts.has("host") && type(opts.host) == "string") { host = opts.host }
        if(opts.has("port")) { port = opts.port }
        if(opts.has("backlog")) { backlog = opts.backlog }
    }
    if(s_ipv4(host) == null) {
        return {"ok":false,"handle":null,"port":0,"error":"invalid IPv4 host: " + host,"error_code":"invalid_address"}
    }
    if(port < 0 || port > 65535) {
        return {"ok":false,"handle":null,"port":0,"error":"invalid port: " + port.to_string(),"error_code":"invalid_address"}
    }
    fd := ffi_call(l, "socket", "i64(i32,i32,i32)", 2, 1, 0)
    if(fd < 0) {
        return {"ok":false,"handle":null,"port":0,"error":"socket creation failed","error_code":"socket_error"}
    }
    sa := ffi_buffer(s_sockaddr4(host, port))
    b := ffi_call(l, "bind", "i32(i64,buffer,i64)", fd, sa, 16)
    if(b != 0) {
        s_close_native(fd)
        return {"ok":false,"handle":null,"port":0,"error":"bind failed","error_code":"address_in_use"}
    }
    lr := ffi_call(l, "listen", "i32(i64,i32)", fd, backlog)
    if(lr != 0) {
        s_close_native(fd)
        return {"ok":false,"handle":null,"port":0,"error":"listen failed","error_code":"socket_error"}
    }
    s_nonblock_native(fd)
    h := s_handle("listener", fd)
    addr := s_address_query(h, false)
    return {"ok":true,"handle":h,"port":addr.port,"error":"","error_code":""}
}
fn(sock_accept(listener)) {
    s_ensure_init()
    if(!s_valid(listener) || listener.kind != "listener") {
        return {"ok":false,"conn":null,"would_block":false,"error":"invalid listener handle","error_code":"invalid_handle"}
    }
    pr := s_pollfd_result(listener.fd, 0, 1)
    if(!pr.readable && !pr.error && !pr.hangup) {
        return {"ok":false,"conn":null,"would_block":true,"error":"","error_code":"would_block"}
    }
    saddr := ffi_buffer(s_zeros(16))
    slen := ffi_buffer(bytes([16, 0, 0, 0, 0, 0, 0, 0]))
    fd := ffi_call(s_lib(), "accept", "i64(i64,buffer,buffer)", listener.fd, saddr, slen)
    if(fd < 0) {
        return {"ok":false,"conn":null,"would_block":false,"error":"accept failed","error_code":"socket_error"}
    }
    s_nonblock_native(fd)
    return {"ok":true,"conn":s_handle("conn", fd),"would_block":false,"error":"","error_code":""}
}
fn(sock_connect(opts)) {
    s_ensure_init()
    l := s_lib()
    host := "127.0.0.1"
    port := 0
    if(type(opts) == "object") {
        if(opts.has("host") && type(opts.host) == "string") { host = opts.host }
        if(opts.has("port")) { port = opts.port }
    }
    if(s_ipv4(host) == null) {
        return {"ok":false,"conn":null,"error":"invalid IPv4 host: " + host,"error_code":"invalid_address"}
    }
    if(port < 1 || port > 65535) {
        return {"ok":false,"conn":null,"error":"invalid port","error_code":"invalid_address"}
    }
    fd := ffi_call(l, "socket", "i64(i32,i32,i32)", 2, 1, 0)
    if(fd < 0) { return {"ok":false,"conn":null,"error":"socket creation failed","error_code":"socket_error"} }
    sa := ffi_buffer(s_sockaddr4(host, port))
    c := ffi_call(l, "connect", "i32(i64,buffer,i64)", fd, sa, 16)
    if(c != 0) {
        s_close_native(fd)
        return {"ok":false,"conn":null,"error":"connection failed","error_code":"connection_refused"}
    }
    s_nonblock_native(fd)
    return {"ok":true,"conn":s_handle("conn", fd),"error":"","error_code":""}
}
fn(sock_recv(conn, max)) {
    s_ensure_init()
    if(!s_valid(conn) || conn.kind != "conn") {
        return {"ok":false,"data":null,"eof":false,"would_block":false,"error":"invalid socket handle","error_code":"invalid_handle"}
    }
    if(max <= 0) { max = 4096 }
    pr := s_pollfd_result(conn.fd, 0, 1)
    if(!pr.readable && !pr.error && !pr.hangup) {
        return {"ok":false,"data":null,"eof":false,"would_block":true,"error":"","error_code":"would_block"}
    }
    sig := "i64(i64,buffer,i64,i32)"
    if(os() == "windows") { sig = "i32(i64,buffer,i64,i32)" }
    buf := ffi_buffer(s_zeros(max))
    rc := ffi_call(s_lib(), "recv", sig, conn.fd, buf, max, 0)
    if(rc == 0) {
        return {"ok":true,"data":bytes(),"eof":true,"would_block":false,"error":"","error_code":""}
    }
    if(rc < 0) {
        if(os() == "windows") {
            e := s_native_err()
            if(e == 10035) { return {"ok":false,"data":null,"eof":false,"would_block":true,"error":"","error_code":"would_block"} }
            return {"ok":false,"data":null,"eof":false,"would_block":false,"error":"recv failed","error_code":"connection_reset"}
        }
        if(s_would_block_now(conn.fd)) {
            return {"ok":false,"data":null,"eof":false,"would_block":true,"error":"","error_code":"would_block"}
        }
        return {"ok":false,"data":null,"eof":false,"would_block":false,"error":"recv failed","error_code":"connection_reset"}
    }
    got := ffi_bytes(buf)
    out := []
    i := 0
    while(i < rc) { out.push(got[i]); i += 1 }
    return {"ok":true,"data":bytes(out),"eof":false,"would_block":false,"error":"","error_code":""}
}
fn(sock_send(conn, data)) {
    return s_send_payload(conn, s_payload_bytes(data))
}
fn(sock_send_all(conn, data)) {
    payload := s_payload_bytes(data)
    total := payload.length()
    if(total == 0) { return {"ok":true,"sent":0,"would_block":false,"error":"","error_code":""} }
    if(!s_valid(conn) || conn.kind != "conn") {
        return {"ok":false,"sent":0,"would_block":false,"error":"invalid socket handle","error_code":"invalid_handle"}
    }
    sent := 0
    while(sent < total) {
        r := s_send_payload(conn, s_bytes_slice(payload, sent, total - sent))
        if(!r.ok) { return r }
        if(r.sent <= 0) {
            return {"ok":false,"sent":sent,"would_block":true,"error":"","error_code":"would_block"}
        }
        sent += r.sent
    }
    return {"ok":true,"sent":sent,"would_block":false,"error":"","error_code":""}
}
fn(sock_shutdown(conn)) {
    if(!s_valid(conn) || conn.kind != "conn") {
        return {"ok":false,"error":"invalid socket handle","error_code":"invalid_handle"}
    }
    ffi_call(s_lib(), "shutdown", "i32(i64,i32)", conn.fd, 2)
    return {"ok":true,"error":"","error_code":""}
}
fn(sock_close(handle)) {
    if(!s_valid(handle)) {
        return {"ok":false,"error":"invalid socket handle","error_code":"invalid_handle"}
    }
    s_close_native(handle.fd)
    socket_open.remove(handle._id)
    return {"ok":true,"error":"","error_code":""}
}
fn(sock_local_address(handle)) { return s_address_query(handle, false) }
fn(sock_peer_address(handle)) { return s_address_query(handle, true) }
fn(sock_poll(items, timeout_ms)) {
    s_ensure_init()
    if(type(items) != "array") {
        return {"ok":false,"results":[],"error":"poll requires an array of handles","error_code":"invalid_argument"}
    }
    n := items.size()
    if(n == 0) { return {"ok":true,"results":[],"error":"","error_code":""} }
    if(os() == "windows") { return s_winsock_poll(items, timeout_ms) }
    k := 0
    ok_all := true
    while(k < n) {
        if(!s_valid(items[k])) { ok_all = false }
        k += 1
    }
    if(!ok_all) {
        return {"ok":false,"results":[],"error":"poll received an invalid handle","error_code":"invalid_handle"}
    }
    seq := []
    for(it : items) {
        le := s_le32(it.fd)
        seq.push(le[0]); seq.push(le[1]); seq.push(le[2]); seq.push(le[3])
        seq.push(5); seq.push(0)
        seq.push(0); seq.push(0)
    }
    buf := ffi_buffer(bytes(seq))
    rc := ffi_call(s_lib(), "poll", "i32(buffer,i64,i32)", buf, n, timeout_ms)
    if(rc < 0) {
        e := 0
        if(os() == "windows") { e = s_native_err() }
        em := "poll failed (native " + e.to_string() + ")"
        return {"ok":false,"results":[],"error":em,"error_code":"socket_error"}
    }
    got := ffi_bytes(buf)
    results := []
    i := 0
    while(i < n) {
        base := i * 16
        if(os() != "windows") { base = i * 8 }
        rv := got[base + 6].to_int() + got[base + 7].to_int() * 256
        if(os() == "windows") { rv = got[base + 10].to_int() + got[base + 11].to_int() * 256 }
        readable := s_bit(rv, 1)
        writable := s_bit(rv, 4)
        err := s_bit(rv, 8)
        hangup := s_bit(rv, 16)
        results.push({"handle":items[i],"readable":readable,"writable":writable,"error":err,"hangup":hangup})
        i += 1
    }
    return {"ok":true,"results":results,"error":"","error_code":""}
}

struct(socket) {
    fn(listen(opts)) { return sock_listen(opts) }
    fn(accept(listener)) { return sock_accept(listener) }
    fn(connect(opts)) { return sock_connect(opts) }
    fn(recv(conn, max)) { return sock_recv(conn, max) }
    fn(send(conn, data)) { return sock_send(conn, data) }
    fn(send_all(conn, data)) { return sock_send_all(conn, data) }
    fn(shutdown(conn)) { return sock_shutdown(conn) }
    fn(close(handle)) { return sock_close(handle) }
    fn(local_address(handle)) { return sock_local_address(handle) }
    fn(peer_address(handle)) { return sock_peer_address(handle) }
    fn(poll(items, timeout_ms)) { return sock_poll(items, timeout_ms) }
}

socket := socket()
export(socket)


fn(sock_available()) { return true }
export(sock_available)
export(sock_listen)
export(sock_accept)
export(sock_connect)
export(sock_recv)
export(sock_send)
export(sock_send_all)
export(sock_shutdown)
export(sock_close)
export(sock_local_address)
export(sock_peer_address)
export(sock_poll)
