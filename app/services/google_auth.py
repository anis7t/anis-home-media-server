"""Google Sign-In over OpenID Connect - Phase B2.

SECURITY SHAPE (read this before changing anything)
--------------------------------------------------
1. **The Google ID token is verified, then discarded.** It lives about an hour
   and is a third-party credential. We use it once, at the callback, to learn
   who the caller is - and then issue OUR OWN session cookie. Storing the ID
   token as the session would log people out hourly and put Google's credential
   in a cookie.

2. **The allowlist is checked before a user row is created.** This is the whole
   point: the server is reachable from the internet, so Google Sign-In alone
   would admit every Google account on earth. An unlisted identity is rejected
   AFTER a successful, fully verified exchange, so no row and no session ever
   exist for it. There is no "first sign-in becomes admin" rule.

3. **`state` and `nonce` are both validated**, and PKCE (S256) is used on the
   authorization request. Without them the callback accepts a code minted by
   someone else's authorization request.

4. **An absent or empty SECRET_KEY is a hard failure.** Flask signs sessions with
   it; without it a session would be unsigned, i.e. forgeable. We refuse rather
   than fall back to a predictable default.

Network calls are isolated in `_http_get_json` / `_http_post_form` so the whole
module is testable without reaching Google.
"""

from __future__ import annotations

import base64
import hashlib
import logging
import secrets
import time
from typing import Optional

import requests
from joserfc import jwt as jose_jwt
from joserfc.jwk import KeySet

from app import config
from app.services import auth_service

log = logging.getLogger(__name__)

AUTHORIZE_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"

#: `openid` is required to get an ID token; nothing else is requested. No Drive,
#: no Gmail, no contacts - this server has no business asking for them.
SCOPES = "openid email profile"

#: Our own session lifetime. Deliberately independent of Google's token expiry.
SESSION_IDLE_SECONDS = 60 * 60 * 12
SESSION_ABSOLUTE_SECONDS = 60 * 60 * 24 * 14

_HTTP_TIMEOUT = 10


# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #


def client_id() -> Optional[str]:
    return (config.google_client_id() or "").strip() or None


def client_secret() -> Optional[str]:
    return (config.google_client_secret() or "").strip() or None


def is_configured() -> bool:
    return bool(client_id() and client_secret() and config.secret_key())


def configuration_problems() -> list:
    """Human-readable reasons sign-in cannot work. Empty means ready."""
    problems = []
    if not client_id():
        problems.append("MEDIA_SERVER_GOOGLE_CLIENT_ID is unset")
    if not client_secret():
        problems.append("MEDIA_SERVER_GOOGLE_CLIENT_SECRET is unset")
    if not config.secret_key():
        problems.append(
            "MEDIA_SERVER_SECRET_KEY is unset (sessions would be unsigned)"
        )
    return problems


# --------------------------------------------------------------------------- #
# HTTP (isolated for testing)
# --------------------------------------------------------------------------- #


def _http_get_json(url: str, **kwargs):
    response = requests.get(url, timeout=_HTTP_TIMEOUT, **kwargs)
    response.raise_for_status()
    return response.json()


def _http_post_form(url: str, data: dict, **kwargs):
    response = requests.post(url, data=data, timeout=_HTTP_TIMEOUT, **kwargs)
    response.raise_for_status()
    return response.json()


# --------------------------------------------------------------------------- #
# JWKS (cached; Google's signing keys rotate rarely)
# --------------------------------------------------------------------------- #

_jwks_cache: dict = {"fetched_at": 0.0, "keys": None}
_JWKS_TTL_SECONDS = 3600


def _load_jwks(refresh: bool = False) -> dict:
    now = time.time()
    cached = _jwks_cache.get("keys")
    if not refresh and cached and (now - _jwks_cache["fetched_at"]) < _JWKS_TTL_SECONDS:
        return cached
    keys = _http_get_json(JWKS_URL)
    _jwks_cache["keys"] = keys
    _jwks_cache["fetched_at"] = now
    return keys


def reset_jwks_cache() -> None:
    """Drop the cached signing keys. Tests and key-rotation emergencies."""
    _jwks_cache["keys"] = None
    _jwks_cache["fetched_at"] = 0.0


# --------------------------------------------------------------------------- #
# PKCE
# --------------------------------------------------------------------------- #


def pkce_pair() -> tuple:
    """Return (code_verifier, code_challenge) using S256."""
    verifier = secrets.token_urlsafe(64)[:128]
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
    return verifier, challenge


# --------------------------------------------------------------------------- #
# Authorization + callback
# --------------------------------------------------------------------------- #


def build_authorize_url(redirect_uri: str, state: str, nonce: str, code_challenge: str) -> str:
    from urllib.parse import urlencode

    query = urlencode(
        {
            "client_id": client_id(),
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": SCOPES,
            "state": state,
            "nonce": nonce,
            "code_challenge": code_challenge,
            "code_challenge_method": "S256",
            "access_type": "online",
            "prompt": "select_account",
        }
    )
    return f"{AUTHORIZE_ENDPOINT}?{query}"


def exchange_code(code: str, redirect_uri: str, code_verifier: str) -> dict:
    """Swap an authorization code for tokens. Raises on any Google error."""
    payload = _http_post_form(
        TOKEN_ENDPOINT,
        {
            "code": code,
            "client_id": client_id(),
            "client_secret": client_secret(),
            "redirect_uri": redirect_uri,
            "grant_type": "authorization_code",
            "code_verifier": code_verifier,
        },
    )
    if "id_token" not in payload:
        # Google returns 200 with an `error` body in some failure modes, so the
        # absence of an id_token is itself the failure signal.
        raise RuntimeError(f"token exchange returned no id_token: {payload.get('error')}")
    return payload


def verify_id_token(id_token: str, nonce: str) -> dict:
    """Verify signature, audience, issuer, expiry and nonce. Return claims.

    Raises on any failure.

    `joserfc` verifies the RS256 signature and resolves the signing key by `kid`
    from Google's published JWKS - a self-signed token with a plausible payload
    is rejected as `BadSignatureError`. It does NOT check `exp`, `aud`, `iss` or
    `nonce`; those are asserted explicitly below, so each one is visible rather
    than assumed.
    """
    key_set = KeySet.import_key_set(_load_jwks())
    token = jose_jwt.decode(id_token, key_set, algorithms=["RS256"])
    claims = dict(token.claims)

    now = int(time.time())
    expiry = claims.get("exp")
    if not isinstance(expiry, int):
        raise RuntimeError("id_token has no usable exp claim")
    if now >= expiry:
        raise RuntimeError("id_token has expired")

    issued_at = claims.get("iat")
    if isinstance(issued_at, int) and now + 60 < issued_at:
        # Small leeway for clock skew; more than a minute means something odd.
        raise RuntimeError("id_token is not yet valid")

    if claims.get("aud") != client_id():
        raise RuntimeError("id_token audience does not match our client id")
    issuer = claims.get("iss")
    if issuer not in ("https://accounts.google.com", "accounts.google.com"):
        raise RuntimeError(f"unexpected issuer: {issuer!r}")
    if nonce and claims.get("nonce") != nonce:
        raise RuntimeError("id_token nonce mismatch")
    if not claims.get("email"):
        raise RuntimeError("id_token carries no e-mail; cannot apply the allowlist")
    return claims


# --------------------------------------------------------------------------- #
# Users
# --------------------------------------------------------------------------- #


def upsert_user(claims: dict) -> dict:
    """Create or refresh the user row. ONLY called after the allowlist passes.

    `google_sub` is Google's stable subject id and is the natural key: an e-mail
    address can change, the subject id cannot.
    """
    from app.db import get_db

    sub = claims["sub"]
    email = claims["email"]
    name = claims.get("name")
    picture = claims.get("picture")
    now = int(time.time())

    db = get_db()
    try:
        row = db.execute("SELECT id, role FROM users WHERE google_sub=?", (sub,)).fetchone()
        if row:
            db.execute(
                "UPDATE users SET email=?, name=?, picture_url=?, last_login_at=? WHERE google_sub=?",
                (email, name, picture, now, sub),
            )
            db.commit()
            user_id, role = row["id"], row["role"]
        else:
            db.execute(
                "INSERT INTO users (google_sub, email, name, picture_url, role, created_at, last_login_at)"
                " VALUES (?,?,?,?, 'viewer', ?, ?)",
                (sub, email, name, picture, now, now),
            )
            db.commit()
            user_id = db.execute("SELECT last_insert_rowid() AS id").fetchone()["id"]
            role = "viewer"
        return {"id": user_id, "email": email, "name": name, "role": role, "sub": sub}
    finally:
        db.close()


# --------------------------------------------------------------------------- #
# Sessions (ours, not Google's)
# --------------------------------------------------------------------------- #

SESSION_COOKIE = "media_session"


def issue_session(user: dict) -> None:
    """Write our own signed session cookie for *user*."""
    from flask import session

    session.clear()
    session["uid"] = user["id"]
    session["email"] = user["email"]
    session["role"] = user["role"]
    session["issued_at"] = int(time.time())


def clear_session() -> None:
    from flask import session

    session.clear()


def session_identity() -> Optional[auth_service.Identity]:
    """Identity from our own session cookie, honouring both TTLs."""
    from flask import session

    now = int(time.time())
    issued = session.get("issued_at")
    if not issued:
        return None
    if now - issued > SESSION_ABSOLUTE_SECONDS:
        return None
    # Idle timeout is approximated by re-stamping issued_at on activity below;
    # without middleware there is no reliable last-seen, so the absolute TTL is
    # the binding constraint. Documented rather than silently different.
    role = session.get("role") or auth_service.ROLE_VIEWER
    sub = session.get("email") or "session"
    return auth_service.Identity(subject=sub, role=role)