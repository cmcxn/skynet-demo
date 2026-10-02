#!/usr/bin/env python3
"""Hermetic HTTP proxy / verified TLS integration tests for a built Skynet.

Usage:
    python3 tests/proxy-integration.py --runtime /path/to/runtime
    python3 tests/proxy-integration.py --runtime /path/to/runtime --case http-proxy

The runtime must contain skynet, cservice/, service/, lualib/, and luaclib/ltls.so.
Tests never modify it. Python standard library and the openssl executable suffice.
All traffic is loopback. A fresh private CA and certs are generated in a temporary
folder. test.invalid names intentionally cannot resolve: the proxy alone maps them
to the local origin. Environment proxy/CA settings are scrubbed for reproducibility.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import fnmatch
import os
from pathlib import Path
import select
import socket
import socketserver
import ssl
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlsplit

TEST_DIR = Path(__file__).resolve().parent
AUTH = "Basic " + base64.b64encode(b"u@ser:p:ss").decode("ascii")


def lua(value):
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r") + '"'
    if isinstance(value, list):
        return "{" + ",".join(lua(x) for x in value) + "}"
    return "{" + ",".join("[" + lua(k) + "]=" + lua(v) for k, v in value.items()) + "}"


def certificate_files(directory):
    def openssl(*args):
        subprocess.run(["openssl", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    ca, key, cert = (directory / name for name in ("ca.pem", "origin.key", "origin.pem"))
    cakey = directory / "ca.key"
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=Skynet integration CA", "-keyout", str(cakey), "-out", str(ca))
    csr = directory / "origin.csr"
    openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=test.invalid", "-keyout", str(key), "-out", str(csr))
    ext = directory / "origin.ext"
    ext.write_text("subjectAltName=DNS:localhost,DNS:test.invalid,DNS:fragment.invalid,DNS:success204.invalid,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n", encoding="ascii")
    openssl("x509", "-req", "-in", str(csr), "-CA", str(ca), "-CAkey", str(cakey), "-CAcreateserial", "-days", "2", "-extfile", str(ext), "-out", str(cert))
    otherca = directory / "wrong-ca.pem"
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=Untrusted integration CA", "-keyout", str(directory / "wrong-ca.key"), "-out", str(otherca))
    capath = directory / "capath"
    capath.mkdir()
    (capath / "ca.pem").write_bytes(ca.read_bytes())
    openssl("rehash", str(capath))
    return ca, key, cert, otherca, capath


def read_header(connection):
    data = bytearray()
    # One byte at a time preserves bytes immediately after CONNECT headers.
    while not data.endswith(b"\r\n\r\n"):
        part = connection.recv(1)
        if not part:
            raise EOFError("peer closed before complete request headers")
        data.extend(part)
        if len(data) > 32768:
            raise ValueError("oversized fixture request header")
    lines = data.decode("iso-8859-1").split("\r\n")
    method, target, protocol = lines[0].split(" ", 2)
    headers = {}
    for line in lines[1:]:
        if line:
            key, value = line.split(":", 1)
            headers[key.lower()] = value.strip()
    return method, target, protocol, headers


def wait_for_eof(connection):
    while connection.recv(4096):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request, client_address):
        # Unexpected fixture failures are retained and fail the relevant case.
        import traceback
        self.fixture.errors.append(traceback.format_exc())


class Server6(Server):
    address_family = socket.AF_INET6


class Fixtures:
    def __init__(self, key, cert):
        self.lock = threading.Lock()
        self.active = {}
        self.serial = 0
        self.origin_requests = []
        self.proxy_requests = []
        self.sni = []
        self.dns_queries = []
        self.dns_clients = []
        self.errors = []
        self.servers = []
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(str(cert), str(key))
        self.context.set_servername_callback(lambda connection, name, context: self.sni.append(name))
        self.http = self.start("http")
        self.https = self.start("https")
        self.proxy = self.start("proxy")
        self.stall = self.start("stall")
        self.trap = self.start("trap")
        self.dns_blackhole = self.start_dns_blackhole()

    def start_dns_blackhole(self):
        fixture = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                data, connection = self.request
                labels = []
                offset = 12
                while offset < len(data) and data[offset]:
                    size = data[offset]
                    offset += 1
                    labels.append(data[offset:offset + size].decode("ascii"))
                    offset += size
                name = ".".join(labels)
                fixture.dns_queries.append(name)
                fixture.dns_clients.append(self.client_address)
                if name == "dns-ok.invalid":
                    # A successful lookup after abandoned waits proves the shared
                    # resolver socket was not closed to cancel an HTTP request.
                    question = data[12:offset + 5]
                    answer = b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\x7f\x00\x00\x01"
                    header = data[:2] + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00"
                    connection.sendto(header + question + answer, self.client_address)
                # Other names deliberately never receive an answer.

        server = socketserver.ThreadingUDPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.servers.append(server)
        return server.server_address[1]

    def start(self, role):
        fixture = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                connection = self.request
                connection.settimeout(12)
                with fixture.lock:
                    fixture.serial += 1
                    ident = fixture.serial
                    fixture.active[ident] = role
                try:
                    if role == "https":
                        connection = fixture.context.wrap_socket(connection, server_side=True)
                        connection.settimeout(12)
                    if role in ("stall", "trap"):
                        wait_for_eof(connection)
                    elif role == "proxy":
                        fixture.handle_proxy(connection)
                    else:
                        method, target, protocol, headers = read_header(connection)
                        if target == "/audit":
                            with fixture.lock:
                                remaining = {i: r for i, r in fixture.active.items() if i != ident}
                            body = str(len(remaining)).encode("ascii")
                            connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                            return
                        fixture.origin_requests.append({"role": role, "method": method, "target": target, "protocol": protocol, "headers": headers})
                        fixture.respond(connection, method, target)
                except (EOFError, ssl.SSLError, ConnectionError, TimeoutError, OSError):
                    pass
                finally:
                    with contextlib.suppress(OSError):
                        connection.close()
                    with fixture.lock:
                        fixture.active.pop(ident, None)

        server = Server(("127.0.0.1", 0), Handler)
        server.fixture = self
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.servers.append(server)
        # libc may resolve localhost to ::1 first. Bind both loopbacks on the
        # same port; never rely on DNS address ordering or bind a public address.
        if role in ("http", "https") and socket.has_ipv6:
            try:
                ipv6 = Server6(("::1", server.server_address[1]), Handler)
            except OSError as error:
                import errno
                if error.errno not in (errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL):
                    raise
            else:
                ipv6.fixture = self
                threading.Thread(target=ipv6.serve_forever, daemon=True).start()
                self.servers.append(ipv6)
        return server.server_address[1]

    def respond(self, connection, method, target):
        path = urlsplit(target).path
        if path == "/timeout-header":
            wait_for_eof(connection)
            return
        if path == "/timeout-stream":
            connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\nX-Origin: loopback\r\n\r\nbegin")
            wait_for_eof(connection)
            return
        if path == "/bad-stream":
            connection.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: unsupported\r\n\r\n")
            wait_for_eof(connection)
            return
        if path == "/chunked":
            connection.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-Origin: loopback\r\n\r\n5\r\nalpha\r\n")
            time.sleep(0.025)
            connection.sendall(b"4\r\nbeta\r\n0\r\n\r\n")
        else:
            response = b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\nX-Origin: loopback\r\n\r\n"
            if path == "/fragment":
                for piece in (response[:7], response[7:30], response[30:-1], response[-1:]):
                    connection.sendall(piece)
                    time.sleep(0.015)
            else:
                connection.sendall(response)
            if method != "HEAD":
                connection.sendall(b"origin-ok")
        # Do not close first: tests must prove the client releases its socket.
        wait_for_eof(connection)

    def handle_proxy(self, connection):
        method, target, protocol, headers = read_header(connection)
        self.proxy_requests.append({"method": method, "target": target, "protocol": protocol, "headers": headers})
        if method == "CONNECT":
            host, port = target.rsplit(":", 1)
            if host.startswith("deny"):
                status = host[4:7]
                connection.sendall(("HTTP/1.1 " + status + " Rejected\r\nContent-Length: 0\r\n\r\n").encode())
                wait_for_eof(connection)
                return
            if host == "connect-timeout.invalid":
                wait_for_eof(connection)
                return
            endpoint = self.stall if host == "tls-timeout.invalid" else self.https
            with socket.create_connection(("127.0.0.1", endpoint), timeout=3) as upstream:
                upstream.settimeout(None)
                status = "204 Tunnel ready" if host == "success204.invalid" else "200 Connection established"
                response = ("HTTP/1.1 " + status + "\r\nX-Proxy: loopback\r\n\r\n").encode()
                if host == "fragment.invalid":
                    for piece in (response[:11], response[11:-3], response[-3:-1], response[-1:]):
                        connection.sendall(piece)
                        time.sleep(0.015)
                else:
                    connection.sendall(response)
                self.relay(connection, upstream)
            return
        parsed = urlsplit(target)
        if parsed.scheme != "http" or not parsed.hostname:
            connection.sendall(b"HTTP/1.1 400 Absolute-form required\r\nContent-Length: 0\r\n\r\n")
            wait_for_eof(connection)
            return
        with socket.create_connection(("127.0.0.1", self.http), timeout=3) as upstream:
            upstream.settimeout(None)
            path = parsed.path or "/"
            if parsed.query:
                path += "?" + parsed.query
            forwarded = f"{method} {path} {protocol}\r\n"
            forwarded += "".join(f"{k}: {v}\r\n" for k, v in headers.items() if k != "proxy-authorization") + "\r\n"
            upstream.sendall(forwarded.encode("iso-8859-1"))
            self.relay(connection, upstream)

    @staticmethod
    def relay(client, upstream):
        readers = {client: upstream, upstream: client}
        deadline = time.monotonic() + 12
        while readers and time.monotonic() < deadline:
            readable, _, _ = select.select(list(readers), [], [], 0.2)
            for source in readable:
                destination = readers[source]
                try:
                    data = source.recv(16384)
                except (ConnectionError, OSError):
                    data = b""
                if data:
                    try:
                        destination.sendall(data)
                    except (ConnectionError, OSError):
                        pass
                else:
                    del readers[source]
                    with contextlib.suppress(OSError):
                        destination.shutdown(socket.SHUT_WR)
                    # Keep the client half alive after upstream EOF. Otherwise
                    # closing the proxy here would conceal client cleanup leaks.

    def reset(self):
        self.origin_requests.clear()
        self.proxy_requests.clear()
        self.sni.clear()
        self.dns_queries.clear()
        self.dns_clients.clear()
        self.errors.clear()

    def close(self):
        for server in self.servers:
            server.shutdown()
            server.server_close()


def scenarios(fixture, ca, wrongca, capath):
    direct_http = f"http://127.0.0.1:{fixture.http}"
    direct_tls = f"https://localhost:{fixture.https}"
    remote_http = f"http://test.invalid:{fixture.http}"
    remote_tls = f"https://test.invalid:{fixture.https}"
    proxy = f"http://u%40ser:p%3Ass@127.0.0.1:{fixture.proxy}"
    trap = f"http://127.0.0.1:{fixture.trap}"
    authorization = {"pRoXy-AuThOrIzAtIoN": "Basic caller-must-not-leak", "X-Test": "preserved"}

    def request(name, host, path="/ok", **kwargs):
        value = {"name": name, "host": host, "path": path, "body": "origin-ok"}
        value.update(kwargs)
        if "headers" in value:
            value["original_proxy_authorization"] = value["headers"]["pRoXy-AuThOrIzAtIoN"]
        return value

    def case(name, env, requests, **kwargs):
        return {"name": name, "env": env, "requests": requests, **kwargs}

    cases = [
        case("direct-http-basic", {}, [request("unchanged direct HTTP", direct_http), request("HTTP origin without scheme", f"127.0.0.1:{fixture.http}")], proxies=0, origins=2),
        case("direct-http", {}, [request("direct HTTP strips proxy credentials", direct_http, headers=authorization)], proxies=0, origins=1),
        case("http-uppercase-ignored", {"HTTP_PROXY": trap}, [request("CGI-safe uppercase HTTP_PROXY ignored", direct_http)], proxies=0, origins=1),
        case("http-proxy", {"http_proxy": proxy}, [request("HTTP absolute-form and Basic userinfo", remote_http, "/ok?query=preserved", headers=authorization)], proxies=1, origins=1, auth=True),
        case("http-proxy-methods", {"http_proxy": proxy}, [request("proxied HEAD", remote_http, method="HEAD", body=""), request("proxied length stream", remote_http, method="STREAM"), request("proxied chunked stream", remote_http, "/chunked", method="STREAM", body="alphabeta"), request("fragmented HTTP response", remote_http, "/fragment")], proxies=4, origins=4, auth=True),
        case("all-proxy-fallback", {"all_proxy": proxy}, [request("all_proxy HTTP fallback", remote_http), request("all_proxy HTTPS fallback", remote_tls, cafile=str(ca))], proxies=2, origins=2, auth=True, sni=["test.invalid"]),
        case("all-proxy-uppercase", {"ALL_PROXY": proxy}, [request("ALL_PROXY fallback", remote_http)], proxies=1, origins=1, auth=True),
        case("http-empty-overrides", {"http_proxy": "", "all_proxy": trap}, [request("empty lowercase http_proxy prevents fallback", direct_http)], proxies=0, origins=1),
        case("service-disable", {"http_proxy": trap, "https_proxy": trap}, [request("per-service proxy disabled", direct_http, proxy=False)], proxies=0, origins=1),
        case("no-proxy-lowercase", {"http_proxy": trap, "no_proxy": "127.0.0.1"}, [request("no_proxy IP bypass", direct_http)], proxies=0, origins=1),
        case("no-proxy-uppercase", {"http_proxy": trap, "NO_PROXY": "localhost"}, [request("NO_PROXY fallback", f"http://localhost:{fixture.http}")], proxies=0, origins=1),
        case("no-proxy-suffix", {"http_proxy": trap, "no_proxy": " .LOCALHOST, unused.invalid "}, [request("case-insensitive dot suffix and whitespace", f"http://localhost:{fixture.http}")], proxies=0, origins=1),
        case("no-proxy-label-boundary", {"http_proxy": proxy, "no_proxy": "est.invalid"}, [request("no_proxy respects DNS label boundary", remote_http)], proxies=1, origins=1, auth=True),
        case("no-proxy-cidr", {"http_proxy": trap, "no_proxy": "127.0.0.0/8"}, [request("no_proxy IPv4 CIDR", direct_http)], proxies=0, origins=1),
        case("no-proxy-wildcard", {"http_proxy": trap, "no_proxy": "*"}, [request("no_proxy wildcard", direct_http)], proxies=0, origins=1),
        case("no-proxy-port", {"http_proxy": trap, "no_proxy": f"127.0.0.1:{fixture.http}"}, [request("no_proxy matching port", direct_http)], proxies=0, origins=1),
        case("no-proxy-wrong-port", {"http_proxy": proxy, "no_proxy": "test.invalid:1"}, [request("no_proxy wrong port does not bypass", remote_http)], proxies=1, origins=1, auth=True),
        case("no-proxy-empty-overrides", {"http_proxy": proxy, "no_proxy": "", "NO_PROXY": "*"}, [request("empty lowercase no_proxy overrides uppercase", remote_http)], proxies=1, origins=1, auth=True),
        case("direct-tls", {}, [request("verified direct hostname TLS", direct_tls, cafile=str(ca), headers=authorization), request("verified direct IP SAN TLS", f"https://127.0.0.1:{fixture.https}", cafile=str(ca))], proxies=0, origins=2, sni=["localhost", None]),
        case("tls-capath", {}, [request("verified TLS hashed capath", direct_tls, capath=str(capath))], proxies=0, origins=1, sni=["localhost"]),
        case("https-proxy", {"https_proxy": proxy, "HTTPS_PROXY": trap}, [request("CONNECT remote DNS and origin-only SNI", remote_tls, cafile=str(ca), headers=authorization)], proxies=1, origins=1, auth=True, sni=["test.invalid"]),
        case("https-uppercase", {"HTTPS_PROXY": proxy}, [request("HTTPS_PROXY uppercase fallback", remote_tls, cafile=str(ca))], proxies=1, origins=1, auth=True, sni=["test.invalid"]),
        case("https-empty-overrides", {"https_proxy": "", "HTTPS_PROXY": trap}, [request("empty lowercase https_proxy disables uppercase", direct_tls, cafile=str(ca))], proxies=0, origins=1, sni=["localhost"]),
        case("https-no-proxy", {"https_proxy": trap, "NO_PROXY": "localhost"}, [request("HTTPS NO_PROXY direct TLS", direct_tls, cafile=str(ca))], proxies=0, origins=1, sni=["localhost"]),
        case("https-methods", {"https_proxy": proxy}, [request("CONNECT HEAD", remote_tls, cafile=str(ca), method="HEAD", body=""), request("CONNECT chunked stream", remote_tls, "/chunked", cafile=str(ca), method="STREAM", body="alphabeta"), request("CONNECT stream explicit close", remote_tls, "/timeout-stream", cafile=str(ca), method="STREAM", close_early=True, body="")], proxies=3, origins=3, auth=True, sni=["test.invalid"] * 3),
        case("connect-fragmented", {"https_proxy": proxy}, [request("fragmented CONNECT headers", f"https://fragment.invalid:{fixture.https}", "/fragment", cafile=str(ca))], proxies=1, origins=1, auth=True, sni=["fragment.invalid"]),
        case("connect-204", {"https_proxy": proxy}, [request("any successful 2xx CONNECT", f"https://success204.invalid:{fixture.https}", cafile=str(ca))], proxies=1, origins=1, auth=True, sni=["success204.invalid"]),
    ]
    for status in (301, 403, 407):
        bad = f"https://deny{status}.invalid:{fixture.https}"
        requests = [request(f"CONNECT {status} rejection {i + 1}", bad, fail=True, cafile=str(ca), error_contains=str(status)) for i in range(5)]
        requests.append(request("valid request after repeated CONNECT failures", remote_tls, cafile=str(ca)))
        cases.append(case(f"connect-reject-{status}", {"https_proxy": proxy}, requests, proxies=6, origins=1, auth=True, sni=["test.invalid"]))
    for name, host, trust, env, proxied in [
        ("tls-untrusted-direct", direct_tls, str(wrongca), {}, False),
        ("tls-default-verification", direct_tls, None, {}, False),
        ("tls-untrusted-proxy", remote_tls, str(wrongca), {"https_proxy": proxy}, True),
        ("tls-ip-san-mismatch", f"https://127.0.0.2:{fixture.https}", str(ca), {"https_proxy": proxy}, True),
        ("tls-hostname-mismatch", f"https://wrong.invalid:{fixture.https}", str(ca), {"https_proxy": proxy}, True),
    ]:
        requests = [request(f"{name} rejection {i + 1}", host, cafile=trust, fail=True) for i in range(4)]
        requests.append(request("valid request after TLS verification failures", direct_tls, cafile=str(ca), proxy=False))
        cases.append(case(name, env, requests, proxies=4 if proxied else 0, origins=1, auth=proxied))
    for name, host, path, method, env, proxied, origins in [
        ("timeout-connect", f"https://connect-timeout.invalid:{fixture.https}", "/ok", "GET", {"https_proxy": proxy}, True, 1),
        ("timeout-tls", f"https://tls-timeout.invalid:{fixture.https}", "/ok", "GET", {"https_proxy": proxy}, True, 1),
        ("timeout-http-response", direct_http, "/timeout-header", "GET", {}, False, 3),
        ("timeout-https-response", remote_tls, "/timeout-header", "GET", {"https_proxy": proxy}, True, 3),
        ("timeout-http-stream", direct_http, "/timeout-stream", "STREAM", {}, False, 3),
        ("timeout-https-stream", remote_tls, "/timeout-stream", "STREAM", {"https_proxy": proxy}, True, 3),
        ("invalid-stream-response", direct_http, "/bad-stream", "STREAM", {}, False, 3),
    ]:
        requests = [request(f"{name} failure {i + 1}", host, path, method=method, cafile=str(ca), fail=True, timeout=20, max_seconds=1.2) for i in range(2)]
        requests.append(request("valid request after timeout/parser failures", direct_http, proxy=False))
        cases.append(case(name, env, requests, proxies=2 if proxied else 0, origins=origins, auth=proxied))
    for name, host, env, query in [
        ("timeout-dns-origin", f"http://dns-timeout.invalid:{fixture.http}", {}, "dns-timeout.invalid"),
        ("timeout-dns-proxy", remote_http, {"http_proxy": f"http://proxy-dns-timeout.invalid:{fixture.proxy}"}, "proxy-dns-timeout.invalid"),
    ]:
        requests = [request(f"{name} failure {i + 1}", host, fail=True, timeout=20, min_seconds=0.1, max_seconds=1.2,
                            dns_server="127.0.0.1", dns_port=fixture.dns_blackhole) for i in range(2)]
        requests.append(request("valid DNS request after resolver timeouts", f"http://dns-ok.invalid:{fixture.http}", proxy=False))
        cases.append(case(name, env, requests, proxies=0, origins=1, dns_queries=[query, query, "dns-ok.invalid"]))
    for name, host, env, proxied in [
        ("timeout-idle-http-stream", direct_http, {}, False),
        ("timeout-idle-https-stream", remote_tls, {"https_proxy": proxy}, True),
    ]:
        requests = [request(name, host, "/timeout-stream", method="STREAM", cafile=str(ca), timeout=20, idle_wait=60, body=""),
                    request("valid request after idle stream expiry", direct_http, proxy=False)]
        cases.append(case(name, env, requests, proxies=1 if proxied else 0, origins=2, auth=proxied))
    for name, badproxy in [
        ("unsupported-proxy-scheme", "socks5://127.0.0.1:1080"),
        ("malformed-proxy-credentials", f"http://u%ZZser:p%3Ass@127.0.0.1:{fixture.proxy}"),
        ("proxy-credential-injection", f"http://user:bad%0d%0aheader@127.0.0.1:{fixture.proxy}"),
    ]:
        cases.append(case(name, {"http_proxy": badproxy}, [request(name + " fails closed", direct_http, fail=True), request("valid request after invalid proxy config", direct_http, proxy=False)], proxies=0, origins=1))
    return cases


def verify_fixture(case, fixture):
    assert not fixture.errors, "fixture error: " + "\n".join(fixture.errors)
    assert len(fixture.proxy_requests) == case["proxies"], f"proxy request count: expected {case['proxies']}, got {len(fixture.proxy_requests)}"
    assert len(fixture.origin_requests) == case["origins"], f"origin request count: expected {case['origins']}, got {len(fixture.origin_requests)}"
    if "dns_queries" in case:
        assert fixture.dns_queries == case["dns_queries"], f"unexpected DNS queries: {fixture.dns_queries!r}"
        assert len(set(fixture.dns_clients)) == 1, "HTTP deadline replaced the shared DNS socket"
    if "sni" in case:
        assert fixture.sni == case["sni"], f"SNI mismatch: expected {case['sni']!r}, got {fixture.sni!r}"
    for item in fixture.proxy_requests:
        if case.get("auth"):
            assert item["headers"].get("proxy-authorization") == AUTH, "proxy Basic credentials were not correctly percent-decoded"
        if item["method"] == "CONNECT":
            assert item["headers"].get("host") == item["target"], "CONNECT Host is not origin authority"
        else:
            assert item["target"].startswith("http://test.invalid:"), "proxy did not receive absolute-form request target"
            assert item["headers"].get("host") == urlsplit(item["target"]).netloc, "HTTP Host does not identify origin"
            assert "u%40ser" not in item["target"] and "p%3Ass" not in item["target"], "userinfo leaked into request target"
    for item in fixture.origin_requests:
        assert "proxy-authorization" not in item["headers"], "proxy credentials reached origin"
        assert item["target"].startswith("/"), "origin received non-origin-form target"
    if case["name"] == "http-proxy":
        assert fixture.proxy_requests[0]["target"].endswith("/ok?query=preserved"), "query changed in absolute-form request"
        assert fixture.origin_requests[0]["headers"].get("x-test") == "preserved", "ordinary caller header lost"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--case", action="append", default=[], help="case name or glob (repeatable); default: all")
    parser.add_argument("--list", action="store_true", help="list cases without running Skynet")
    parser.add_argument("--process-timeout", type=float, default=8, help="per-scenario watchdog seconds (default: 8)")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    if not (runtime / "skynet").is_file():
        parser.error("--runtime must contain the built skynet executable")
    failures = []
    with tempfile.TemporaryDirectory(prefix="skynet-proxy-tests-") as temp:
        directory = Path(temp)
        ca, key, cert, wrongca, capath = certificate_files(directory)
        fixture = Fixtures(key, cert)
        try:
            cases = scenarios(fixture, ca, wrongca, capath)
            cases = [case for case in cases if not args.case or any(fnmatch.fnmatchcase(case["name"], pattern) for pattern in args.case)]
            if not cases:
                parser.error("no cases match --case")
            if args.list:
                print("\n".join(case["name"] for case in cases))
                return 0
            for case in cases:
                fixture.reset()
                result = directory / (case["name"] + ".result")
                casefile = directory / (case["name"] + ".lua")
                casefile.write_text("return " + lua({"requests": case["requests"], "audit_host": f"http://127.0.0.1:{fixture.http}"}) + "\n", encoding="utf-8")
                env = {key: value for key, value in os.environ.items() if key.lower() not in ("http_proxy", "https_proxy", "no_proxy", "all_proxy", "ssl_cert_file", "ssl_cert_dir")}
                env.update(case["env"])
                env.update(PROXY_TEST_DIR=str(TEST_DIR), PROXY_CASE_FILE=str(casefile), PROXY_RESULT_FILE=str(result))
                output = ""
                try:
                    completed = subprocess.run([str(runtime / "skynet"), str(TEST_DIR / "config-proxy")], cwd=runtime, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=args.process_timeout)
                    output = completed.stdout
                    assert completed.returncode == 0, f"Skynet exited {completed.returncode}"
                    assert result.is_file(), "Skynet produced no test result"
                    outcome = result.read_text(encoding="utf-8")
                    assert outcome == "PASS\n", outcome.strip()
                    verify_fixture(case, fixture)
                    print("PASS " + case["name"], flush=True)
                    if args.verbose:
                        print(output, end="")
                except (AssertionError, subprocess.TimeoutExpired) as error:
                    if isinstance(error, subprocess.TimeoutExpired):
                        output = error.stdout or b""
                        if isinstance(output, bytes):
                            output = output.decode("utf-8", "replace")
                        reason = f"watchdog expired after {args.process_timeout}s; request timeout or cleanup did not finish"
                    else:
                        reason = str(error)
                    failures.append(case["name"])
                    print(f"FAIL {case['name']}: {reason}", flush=True)
                    print(output, end="" if output.endswith("\n") else "\n")
                # Child termination closes remaining sockets before the next case.
                deadline = time.monotonic() + 1
                while fixture.active and time.monotonic() < deadline:
                    time.sleep(0.01)
            print(f"\n{len(cases) - len(failures)}/{len(cases)} scenarios passed", flush=True)
            if failures:
                print("Failed: " + ", ".join(failures), flush=True)
                return 1
            return 0
        finally:
            fixture.close()


if __name__ == "__main__":
    raise SystemExit(main())
