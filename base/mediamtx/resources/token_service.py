#!/usr/bin/env python3
"""Per-stream viewer tokens and auth hook for MediaMTX. Standard library only.

POST /token   Authorization: Bearer <TOKEN_API_KEY>
              {"path": "bbb", "ttl": 300, "viewer": "alice"}
              -> 201 {"token", "path", "expires_at", "whep_url", "page_url"}
POST /auth    MediaMTX `authMethod: http` hook (cluster-internal only):
              WebRTC reads need a valid token for exactly that path (never
              an hls/ path), HLS reads are denied (HLS is CDN-only: CDN
              requests carry hlsCDNSecret and never reach the hook), control
              API calls need the
              MEDIAMTX_API_USER/PASSWORD Basic-auth credentials (used by the
              config service), RTSP publishing from loopback is allowed (the
              replica's own runOnDemand ffmpeg, which re-encodes camera audio
              to Opus; RTSP listens on 127.0.0.1 only), everything else is
              denied.
GET  /healthz

Tokens are HS256 JWTs signed with SIGNING_KEY. Nothing is stored, so any
number of replicas can serve both endpoints. A token is checked when a viewer
starts a session; an expired token does not cut off a session in progress.
"""
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import signal
import sys
import time
import urllib.parse
from base64 import urlsafe_b64decode, urlsafe_b64encode
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SIGNING_KEY = os.environ["SIGNING_KEY"].encode()
TOKEN_API_KEY = os.environ["TOKEN_API_KEY"].encode()
MEDIAMTX_API_USER = os.environ["MEDIAMTX_API_USER"].encode()
MEDIAMTX_API_PASSWORD = os.environ["MEDIAMTX_API_PASSWORD"].encode()
ISSUER = os.environ.get("ISSUER", "mediamtx-token")
DEFAULT_TTL = int(os.environ.get("DEFAULT_TTL", "300"))
MAX_TTL = int(os.environ.get("MAX_TTL", "3600"))
PUBLIC_WEBRTC_URL = os.environ.get("PUBLIC_WEBRTC_URL", "").rstrip("/")
PORT = int(os.environ.get("PORT", "8080"))
MAX_BODY = 64 * 1024
PATH_RE = re.compile(r"[A-Za-z0-9_.~-]+(/[A-Za-z0-9_.~-]+)*")
# HLS cameras live under this prefix; they must never be served over WebRTC.
HLS_PREFIX = "hls/"

log = logging.getLogger("token")


def b64url(data: bytes) -> str:
    return urlsafe_b64encode(data).rstrip(b"=").decode()


def b64url_decode(s: str) -> bytes:
    return urlsafe_b64decode(s + "=" * (-len(s) % 4))


JWT_HEADER = b64url(b'{"alg":"HS256","typ":"JWT"}')


def sign(claims: dict) -> str:
    payload = b64url(json.dumps(claims, separators=(",", ":")).encode())
    mac = hmac.new(SIGNING_KEY, f"{JWT_HEADER}.{payload}".encode(), hashlib.sha256)
    return f"{JWT_HEADER}.{payload}.{b64url(mac.digest())}"


def verify(token: str):
    """Return the claims of a valid, unexpired token issued here, else None."""
    parts = token.split(".")
    if len(parts) != 3 or parts[0] != JWT_HEADER:
        return None
    header, payload, sig = parts
    mac = hmac.new(SIGNING_KEY, f"{header}.{payload}".encode(), hashlib.sha256)
    try:
        if not hmac.compare_digest(mac.digest(), b64url_decode(sig)):
            return None
        claims = json.loads(b64url_decode(payload))
    except ValueError:  # bad base64 / JSON / UTF-8
        return None
    if not isinstance(claims, dict) or claims.get("iss") != ISSUER:
        return None
    exp = claims.get("exp")
    if not isinstance(exp, int) or exp <= time.time():
        return None
    return claims


def token_from_hook(body: dict) -> str:
    # MediaMTX fills "token" from `Authorization: Bearer` (or the Basic-auth
    # password); for HTTP auth it does not parse ?token= itself, but forwards
    # the raw query (the built-in player page passes it on to WHEP).
    # Any caller in the cluster can POST here: non-string fields count as absent.
    token, query = body.get("token"), body.get("query")
    if token and isinstance(token, str):
        return token
    if not isinstance(query, str):
        return ""
    return urllib.parse.parse_qs(query).get("token", [""])[0]


class Handler(BaseHTTPRequestHandler):
    server_version = "mediamtx-token"
    # Socket timeout for every read, including the request body: a client that
    # declares a Content-Length and then stalls (slowloris) frees its thread
    # after this many seconds instead of holding it forever.
    timeout = 10

    def log_message(self, fmt, *args):
        log.debug("%s %s", self.address_string(), fmt % args)

    def reply(self, status, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(status)
        if obj is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if urllib.parse.urlsplit(self.path).path == "/healthz":
            return self.reply(200, {"status": "ok"})
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        route = urllib.parse.urlsplit(self.path).path
        if route not in ("/token", "/auth"):
            return self.reply(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 <= length <= MAX_BODY:
                raise ValueError
            body = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(body, dict):
                raise ValueError
        except TimeoutError:  # body not sent within `timeout`
            self.close_connection = True
            return
        except ValueError:
            return self.reply(400, {"error": "invalid JSON body"})
        if route == "/token":
            return self.issue(body)
        return self.authorize(body)

    def issue(self, body):
        auth = self.headers.get("Authorization", "").encode()
        if not hmac.compare_digest(auth, b"Bearer " + TOKEN_API_KEY):
            return self.reply(401, {"error": "invalid API key"})

        path = body.get("path")
        if (not isinstance(path, str) or not PATH_RE.fullmatch(path)
                or any(seg in (".", "..") for seg in path.split("/"))):
            return self.reply(400, {"error": "invalid path"})
        if path.startswith(HLS_PREFIX):
            return self.reply(400, {"error": "hls/ paths are HLS cameras, not available over WebRTC"})
        ttl = body.get("ttl", DEFAULT_TTL)
        if isinstance(ttl, bool) or not isinstance(ttl, int) or not 1 <= ttl <= MAX_TTL:
            return self.reply(400, {"error": f"ttl must be an integer in 1..{MAX_TTL}"})
        viewer = body.get("viewer")
        if viewer is not None and (not isinstance(viewer, str) or len(viewer) > 128):
            return self.reply(400, {"error": "invalid viewer"})

        now = int(time.time())
        claims = {"iss": ISSUER, "iat": now, "exp": now + ttl,
                  "jti": secrets.token_urlsafe(12), "path": path}
        if viewer:
            claims["sub"] = viewer
        token = sign(claims)

        res = {"token": token, "path": path, "expires_at": claims["exp"]}
        if PUBLIC_WEBRTC_URL:
            res["whep_url"] = f"{PUBLIC_WEBRTC_URL}/{path}/whep"
            res["page_url"] = f"{PUBLIC_WEBRTC_URL}/{path}/?token={token}"
        log.info("issued jti=%s path=%s ttl=%d viewer=%s", claims["jti"], path, ttl, viewer)
        self.reply(201, res)

    def authorize(self, body):
        action, protocol, path = body.get("action"), body.get("protocol"), body.get("path")
        ip, sid = body.get("ip"), body.get("id")

        if action == "read" and protocol == "hls":
            if sid is None:
                # The built-in player page: MediaMTX auth-checks it even for CDN
                # requests, but it carries no session id and serves only static
                # HTML -- playback (a session) still needs the CDN.
                log.debug("allow hls page path=%s ip=%s", path, ip)
                return self.reply(204)
            log.info("deny hls read path=%s ip=%s: HLS is CDN-only", path, ip)
            return self.reply(401, {"error": "HLS is only available through the CDN"})

        if action == "read" and protocol == "webrtc":
            token = token_from_hook(body)
            claims = verify(token) if token else None
            if claims and claims.get("path") == path and not path.startswith(HLS_PREFIX):
                log.info("allow webrtc read path=%s jti=%s viewer=%s ip=%s session=%s",
                         path, claims["jti"], claims.get("sub"), ip, sid)
                return self.reply(204)
            reason = "no token" if not token else "invalid/expired token" if not claims else "wrong path"
            log.info("deny webrtc read path=%s ip=%s: %s", path, ip, reason)
            return self.reply(401, {"error": reason})

        if action == "publish" and protocol == "rtsp" and ip in ("127.0.0.1", "::1"):
            # The replica's runOnDemand ffmpeg publishing a camera with its audio
            # re-encoded to Opus. RTSP is bound to 127.0.0.1, so only processes
            # inside the replica pod can get here.
            log.debug("allow local publish path=%s", path)
            return self.reply(204)

        if action == "api":
            # Both compared (no short-circuit) to keep timing independent of which is wrong.
            user_ok = hmac.compare_digest(str(body.get("user") or "").encode(), MEDIAMTX_API_USER)
            pass_ok = hmac.compare_digest(str(body.get("password") or "").encode(), MEDIAMTX_API_PASSWORD)
            if user_ok and pass_ok:
                log.debug("allow api ip=%s", ip)
                return self.reply(204)
            log.info("deny api ip=%s: bad credentials", ip)
            return self.reply(401, {"error": "bad credentials"})

        log.info("deny action=%s protocol=%s path=%s ip=%s", action, protocol, path, ip)
        self.reply(401, {"error": "not allowed"})


def main():
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(message)s")
    # Running as PID 1: exit promptly on SIGTERM.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    ThreadingHTTPServer.daemon_threads = True
    server = ThreadingHTTPServer(("", PORT), Handler)
    log.info("listening on :%d (issuer=%s, default ttl=%ds, max ttl=%ds)",
             PORT, ISSUER, DEFAULT_TTL, MAX_TTL)
    server.serve_forever()


if __name__ == "__main__":
    main()
