"""API token system - Phase C.

WHY A TOKEN IS AN IDENTITY, NOT JUST A KEY
------------------------------------------
The goal is one signed-in person across the web app, the Android app and the TV,
with watch history and player settings following them between devices. That only
works if a token is BOUND TO A USER: otherwise "the thing playing on the living
room TV" and "Anis Parvez" are unconnected, and history cannot follow you.

So a token resolves to the same `Identity` a browser session does. The TV signs
in once (by redeeming a pairing link), receives a token bound to that user, and
from then on reports as that user.

STORAGE
-------
Tokens are shown exactly once and stored only as a SHA-256 hash. A plain hash is
correct here rather than a slow KDF: these are 256-bit random values, not
user-chosen passwords, so there is nothing to brute-force.

SCOPE
-----
A token inherits the user's role. Tokens can never exceed their user, and
minting a token requires admin - so one leaked TV token is not admin access.
"""

from __future__ import annotations

import hashlib
import logging
import secrets
import time
from typing import Optional

from app.db import get_db

log = logging.getLogger(__name__)

#: Visible prefix so a token is recognisable in a log, a screenshot or a secret
#: scanner, and cannot be mistaken for a password.
TOKEN_PREFIX = "ms_"

#: 32 bytes = 256 bits of entropy.
TOKEN_ENTROPY_BYTES = 32

DEFAULT_VALIDITY_DAYS = 90


def hash_token(token: str) -> str:
    """The stored form. Deterministic, so lookup is a single indexed query."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def generate_token() -> str:
    return TOKEN_PREFIX + secrets.token_urlsafe(TOKEN_ENTROPY_BYTES)


def create_token(user_id: int, label: str, validity_days: Optional[int] = DEFAULT_VALIDITY_DAYS) -> tuple:
    """Create a token. Returns (plaintext, record) - the plaintext is never stored.

    The caller must show the plaintext to the operator exactly once. Losing it is
    not recoverable; revoke and mint another.
    """
    plaintext = generate_token()
    now = int(time.time())
    expires_at = now + validity_days * 86400 if validity_days else None

    db = get_db()
    try:
        cursor = db.execute(
            "INSERT INTO auth_tokens (user_id, label, token_hash, created_at, expires_at)"
            " VALUES (?,?,?,?,?)",
            (user_id, label, hash_token(plaintext), now, expires_at),
        )
        db.commit()
        token_id = cursor.lastrowid
    finally:
        db.close()

    return plaintext, {
        "id": token_id,
        "user_id": user_id,
        "label": label,
        "created_at": now,
        "expires_at": expires_at,
    }


def list_tokens(user_id: Optional[int] = None) -> list:
    """Metadata only. The token itself is unrecoverable by design."""
    db = get_db()
    try:
        if user_id is None:
            rows = db.execute(
                "SELECT id, user_id, label, created_at, last_used_at, expires_at, revoked_at"
                " FROM auth_tokens ORDER BY created_at DESC"
            ).fetchall()
        else:
            rows = db.execute(
                "SELECT id, user_id, label, created_at, last_used_at, expires_at, revoked_at"
                " FROM auth_tokens WHERE user_id=? ORDER BY created_at DESC",
                (user_id,),
            ).fetchall()
        return [dict(row) for row in rows]
    finally:
        db.close()


def revoke_token(token_id: int) -> bool:
    db = get_db()
    try:
        cursor = db.execute(
            "UPDATE auth_tokens SET revoked_at=? WHERE id=? AND revoked_at IS NULL",
            (int(time.time()), token_id),
        )
        db.commit()
        return cursor.rowcount > 0
    finally:
        db.close()


def resolve_token(plaintext: str) -> Optional[dict]:
    """Return the token's user record, or None.

    Checks revocation and expiry, and stamps `last_used_at`. An unknown,
    revoked or expired token is indistinguishable from a wrong one to the
    caller - all return None.
    """
    if not plaintext or not isinstance(plaintext, str):
        return None
    if not plaintext.startswith(TOKEN_PREFIX):
        # Cheap reject before any database work.
        return None

    now = int(time.time())
    db = get_db()
    try:
        row = db.execute(
            "SELECT t.id AS token_id, t.user_id, t.expires_at, t.revoked_at,"
            "       u.email, u.name, u.picture_url, u.role"
            " FROM auth_tokens t JOIN users u ON u.id = t.user_id"
            " WHERE t.token_hash=?",
            (hash_token(plaintext),),
        ).fetchone()
        if row is None:
            return None
        if row["revoked_at"] is not None:
            return None
        if row["expires_at"] is not None and now >= row["expires_at"]:
            return None

        db.execute(
            "UPDATE auth_tokens SET last_used_at=? WHERE id=?", (now, row["token_id"])
        )
        db.commit()
        return dict(row)
    finally:
        db.close()


def extract_bearer(header_value: Optional[str]) -> Optional[str]:
    """Pull the token out of an `Authorization: Bearer <token>` header."""
    if not header_value:
        return None
    parts = header_value.strip().split(None, 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        return None
    token = parts[1].strip()
    return token or None


def pairing_payload(plaintext: str, server_origin: str) -> str:
    """A one-time link a TV can open to exchange for its token.

    Used instead of typing a token on a 10-foot remote. The token travels in the
    URL fragment, which browsers do not send to servers in a request line - so
    it is not written into Cloudflare or Waitress access logs on the way.
    """
    from urllib.parse import quote

    return f"{server_origin.rstrip('/')}/auth/pair#{quote(plaintext, safe='')}"