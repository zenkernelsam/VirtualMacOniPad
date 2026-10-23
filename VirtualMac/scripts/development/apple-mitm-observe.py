#!/usr/bin/env python3
"""Minimal MITM proxy for observing AppleAccount AOS traffic from the VM.

NOTE (2026-10-23): Apple pins certificates on gsa.apple.com
(AppleIDAuthSupport) and setup.icloud.com (AAURLSession); both abort the
TLS handshake with a locally trusted CA, so this tool is kept for
non-pinned debugging only. See docs/WORKLOG.md.

Only hosts under icloud.com / apple.com are terminated; everything else is a
blind CONNECT tunnel so the rest of the system keeps working. Logs request
and response heads plus bodies (capped) to /tmp/mitm-<ts>.log.

Set MITM_REWRITE=1 to substitute the VM's device descriptors with the iPad's
(UDID/serial) in request line, headers and body.
"""
import os, socket, ssl, struct, sys, threading, time, datetime

LISTEN = ("127.0.0.1", 8888)
CERT = "/tmp/mitm-cert.pem"
KEY = "/tmp/mitm-key.pem"
TS = time.strftime("%H%M%S")
LOG = f"/tmp/mitm-{TS}.log"
LOCK = threading.Lock()

IPAD_UDID = "AE1C4759-51A7-5455-B6CB-3B3CF98D4EA3"
IPAD_SERIAL = "R9D3WPY7T5"
VM_UDID = "B39EFD32-C664-596A-B3EE-E3024771A962"
VM_SERIAL = "Z6PNXXV1RW"
REWRITE = os.environ.get("MITM_REWRITE", "0") == "1"
CAP = 96 * 1024


def log(msg):
    with LOCK:
        with open(LOG, "a", errors="replace") as f:
            f.write(msg.rstrip("\n") + "\n")
        print(msg, flush=True)


def is_target(host):
    h = host.lower()
    # gsa.apple.com is certificate-pinned by AppleIDAuthSupport; MITM there
    # breaks SRP. Only terminate the AOS login endpoint.
    return h == "setup.icloud.com"


def recv_head(sock, buf=b""):
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            return None, buf
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    return head, rest


def read_body(sock, rest, headers):
    h = {k.lower(): v.strip() for k, v in headers}
    if "content-length" in h:
        n = int(h["content-length"])
        data = rest[:n]
        while len(data) < n:
            chunk = sock.recv(n - len(data))
            if not chunk:
                break
            data += chunk
        return data, b""
    if h.get("transfer-encoding", "").lower() == "chunked":
        data = rest
        while True:
            while b"\r\n" not in data:
                c = sock.recv(4096)
                if not c:
                    return data, b""
                data += c
            size_line, _, data = data.partition(b"\r\n")
            size = int(size_line.split(b";")[0], 16)
            while len(data) < size + 2:
                c = sock.recv(4096)
                if not c:
                    return data, b""
                data += c
            chunk = data[:size]
            data = data[size + 2:]
            if size == 0:
                return data, b""
        # unreachable
    return b"", rest


def parse_headers(head):
    lines = head.split(b"\r\n")
    start = lines[0].decode("latin1")
    headers = []
    for ln in lines[1:]:
        if b":" in ln:
            k, v = ln.split(b":", 1)
            headers.append((k.decode("latin1").strip(), v.decode("latin1").strip()))
    return start, headers


def rewrite(start, headers, body):
    uid, ser = IPAD_UDID, IPAD_SERIAL
    start = start.replace(VM_UDID, uid).replace(VM_SERIAL, ser)
    out = []
    for k, v in headers:
        kl = k.lower()
        if kl in ("x-appleid-device-udid", "x-client-udid"):
            v = uid
        elif kl == "x-apple-i-srl-no":
            v = ser
        elif "udid" in v.lower() or "serial" in v.lower() or kl.startswith("x-mme-client-info"):
            v = v.replace(VM_UDID, uid).replace(VM_SERIAL, ser)
        out.append((k, v))
    if body:
        body = body.replace(VM_UDID.encode(), uid.encode()).replace(VM_SERIAL.encode(), ser.encode())
    return start, out, body


def build_head(start, headers, body):
    h = start + "\r\n" + "\r\n".join(f"{k}: {v}" for k, v in headers) + "\r\n\r\n"
    return h.encode("latin1") + body


def preview(data):
    if not data:
        return "(empty)"
    s = data.decode("utf-8", errors="replace")
    if len(s) > CAP:
        s = s[:CAP] + f"...[{len(data)} bytes]"
    return s


def mitm(client, host, port):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    ctx.set_alpn_protocols(["http/1.1"])
    try:
        tls = ctx.wrap_socket(client, server_side=True)
    except Exception as e:
        log(f"[{host}] TLS handshake failed: {e}")
        return
    up = None
    try:
        while True:
            head, rest = recv_head(tls)
            if head is None:
                return
            start, headers = parse_headers(head)
            body, rest2 = read_body(tls, rest, headers)
            if up is None:
                raw = socket.create_connection((host, port), timeout=20)
                uctx = ssl.create_default_context()
                uctx.set_alpn_protocols(["http/1.1"])
                up = uctx.wrap_socket(raw, server_hostname=host)
            log(f"\n=== {datetime.datetime.now().strftime('%H:%M:%S')} {host} {start}")
            for k, v in headers:
                log(f"  > {k}: {v}")
            if body:
                log("  > BODY: " + preview(body))
            if REWRITE:
                start, headers, body = rewrite(start, headers, body)
            up.sendall(build_head(start, headers, body))
            rhead, rrest = recv_head(up)
            if rhead is None:
                log("  < connection closed")
                return
            rstart, rheaders = parse_headers(rhead)
            rbody, rrest2 = read_body(up, rrest, rheaders)
            log("  < " + rstart)
            for k, v in rheaders:
                log(f"  < {k}: {v}")
            if rbody:
                log("  < BODY: " + preview(rbody))
            tls.sendall(build_head(rstart, rheaders, rbody))
            if rest2:
                # pipelined bytes: next loop picks them from the socket anyway
                pass
    except Exception as e:
        log(f"[{host}] error: {e}")
    finally:
        for s in (tls, up):
            try:
                s and s.close()
            except Exception:
                pass


def blind(client, host, port):
    try:
        up = socket.create_connection((host, port), timeout=20)
    except Exception as e:
        log(f"[{host}] tunnel connect failed: {e}")
        client.close()
        return
    client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")

    def pump(a, b):
        try:
            while True:
                d = a.recv(65536)
                if not d:
                    break
                b.sendall(d)
        except Exception:
            pass
        finally:
            for s in (a, b):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except Exception:
                    pass

    t = threading.Thread(target=pump, args=(client, up), daemon=True)
    t.start()
    pump(up, client)


def handle(client, addr):
    try:
        head, rest = recv_head(client)
        if head is None:
            client.close()
            return
        line = head.split(b"\r\n")[0].decode("latin1")
        parts = line.split()
        if len(parts) < 2 or parts[0] != "CONNECT":
            client.close()
            return
        host, _, port = parts[1].partition(":")
        port = int(port or 443)
        if is_target(host):
            log(f"[{host}] MITM (rewrite={REWRITE})")
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            mitm(client, host, port)
        else:
            blind(client, host, port)
    except Exception as e:
        log(f"handle error: {e}")
        try:
            client.close()
        except Exception:
            pass


def main():
    log(f"proxy listening {LISTEN} rewrite={REWRITE} log={LOG}")
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN)
    srv.listen(64)
    while True:
        c, a = srv.accept()
        threading.Thread(target=handle, args=(c, a), daemon=True).start()


if __name__ == "__main__":
    main()
