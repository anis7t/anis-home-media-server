"""Phase C5c - OAuth state now lives in the database, not the session cookie.

This defends the exact production bug that produced "Sign-in state is missing":
Safari ITP / Firefox ETP drop the session cookie across the redirect from
accounts.google.com back to this origin. The callback therefore arrives with no
session cookie, and a server that kept the state in `session["_oauth_state"]`
would refuse every affected browser.

The fix: `/auth/google` writes state/nonce/verifier into the `oauth_attempts`
table; the callback reads it from there. A caller with NO session cookie must
succeed if the state is in the DB.
"""
import time

import pytest
import base64
from cryptography.hazmat.primitives.asymmetric import rsa
from joserfc import jwk as jose_jwk
from joserfc import jwt as jose_jwt

import app
from app.db import get_db
from app.services import auth_service, google_auth


# --------------------------------------------------------------------------- #
# Real RSA keys and real signed tokens (same pattern as test_google_auth.py)
# --------------------------------------------------------------------------- #

_GOOGLE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_ATTACKER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _sign(private_key, claims, kid="google-1"):
    return jose_jwt.encode(
        {"alg": "RS256", "kid": kid},
        claims,
        jose_jwk.RSAKey.import_key(private_key),
        algorithms=["RS256"],
    )


def _public_jwks(private_key, kid="google-1"):
    numbers = private_key.public_key().public_numbers()

    def b64(value):
        raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")

    return {
        "keys": [
            {
                "kty": "RSA",
                "kid": kid,
                "use": "sig",
                "alg": "RS256",
                "n": b64(numbers.n),
                "e": b64(numbers.e),
            }
        ]
    }


def _claims(**overrides):
    base = {
        "iss": "https://accounts.google.com",
        "aud": "85510759893-ddr1up2e3kbhg24pf2hdrroh91nrb06b.apps.googleusercontent.com",
        "azp": "85510759893-ddr1up2e3kbhg24pf2hdrroh91nrb06b.apps.googleusercontent.com",
        "sub": "111111111111",
        "email": "owner@example.com",
        "email_verified": True,
        "exp": int(time.time()) + 3600,
        "iat": int(time.time()) - 10,
    }
    base.update(overrides)
    return base


def _stub_exchange(monkeypatch, id_token):
    monkeypatch.setattr(
        google_auth,
        "exchange_code",
        lambda code, redirect_uri, verifier: {"id_token": id_token},
    )


def _begin():
    """Start a sign-in and return the Location so state/nonce can be read."""
    with app.app.test_client() as c:
        location = c.get("/auth/google").headers["Location"]
    from urllib.parse import parse_qs, urlparse

    query = parse_qs(urlparse(location).query)
    return query["state"][0], query["nonce"][0]


@pytest.fixture(autouse=True)
def google_env(monkeypatch):
    """Self-contained Google / auth configuration for this module."""
    monkeypatch.setenv("MEDIA_SERVER_GOOGLE_CLIENT_ID",
                       "85510759893-ddr1up2e3kbhg24pf2hdrroh91nrb06b.apps.googleusercontent.com")
    monkeypatch.setenv("MEDIA_SERVER_GOOGLE_CLIENT_SECRET", "test-secret")
    monkeypatch.setenv("MEDIA_SERVER_SECRET_KEY", "unit-test-secret-key-for-verify")
    monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "owner@example.com")
    # `app.app` was already created at import time; its secret_key was computed
    # then, so mirror it explicitly once more here.
    app.app.secret_key = "unit-test-secret-key-for-verify"
    # Conftest redirects MEDIA_SERVER_DATABASE to a throwaway temp DB that has
    # no schema until it is initialized; mirror the pattern in test_google_auth.py.
    app.init_db()
    # Our tokens use kid="google-1"; the verifier fetches JWKS from Google's
    # real endpoint otherwise. Reset the cache and serve our test key.
    google_auth.reset_jwks_cache()
    monkeypatch.setattr(
        google_auth, "_load_jwks", lambda *a, **k: _public_jwks(_GOOGLE_KEY)
    )
    yield


# --------------------------------------------------------------------------- #
# The fix: state read from the DB, not the dropped session cookie
# --------------------------------------------------------------------------- #

def test_callback_succeeds_with_dropped_session_cookie(monkeypatch):
    """No session cookie arrives: state came from the server-side store.

    This is the Safari ITP / Firefox ETP condition that produced the bug.
    The state/nonce/verifier are read from `oauth_attempts`, so a fresh,
    cookieless client that holds only the URL's state can complete sign-in.

    The callback responds with our own `media_session` cookie (issued via
    `google_auth.issue_session`). A browser that survived the redirect with
    a dropped cookie gets its session back at the callback response - which is
    what lets the NEXT request arrive authenticated.
    """
    state, nonce = _begin()
    _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce=nonce)))

    # Fresh client with NO cookie — the cookie that /auth/google set is gone.
    fresh = app.app.test_client(use_cookies=False)
    response = fresh.get(f"/auth/google/callback?code=abc&state={state}")
    assert response.status_code == 302, response.data

    # The session is issued at the callback response, so the browser's next
    # request will carry it. (A cookieless client cannot hold a cookie it was
    # just told about; prove issuance via the Set-Cookie header.)
    #
    # Search *all* Set-Cookie headers rather than the first: the app also stamps
    # `ms_device_id` app-wide, so ordering is not a property worth asserting.
    # What matters is that our signed session cookie is among them.
    set_cookie = [value for name, value in response.headers if name.lower() == "set-cookie"]
    assert set_cookie, "expected a session cookie to be issued"
    assert any("session=" in value for value in set_cookie), (
        f"expected our signed session cookie among {set_cookie}"
    )


def test_callback_reuses_db_nonce_not_url_nonce(monkeypatch):
    """A cookieless client can only win with the nonce from the DB.

    The callback reads the nonce out of `oauth_attempts` (secrets that only
    our server knows) and rejects a token signed with a different nonce,
    proving the verifier reads live secrets from the store rather than
    trusting anything the browser sends.
    """
    state, _ = _begin()
    _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce="wrong-nonce")))

    fresh = app.app.test_client(use_cookies=False)
    response = fresh.get(f"/auth/google/callback?code=abc&state={state}")
    assert response.status_code == 401, response.data


def test_state_is_one_time_replay_blocked(monkeypatch):
    """Once the state is consumed it cannot be replayed, even by a fresh client."""
    state, nonce = _begin()
    _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce=nonce)))

    fresh = app.app.test_client(use_cookies=False)
    first = fresh.get(f"/auth/google/callback?code=abc&state={state}")
    assert first.status_code == 302, first.data

    second = fresh.get(f"/auth/google/callback?code=abc&state={state}")
    assert second.status_code == 400, second.data


def test_non_allowlisted_email_refused_without_any_session(monkeypatch):
    """Allowlist still gates at the callback, even with zero session cookies."""
    state, nonce = _begin()
    _stub_exchange(monkeypatch,
                   _sign(_GOOGLE_KEY, _claims(email="stranger@example.com", nonce=nonce)))

    fresh = app.app.test_client(use_cookies=False)
    response = fresh.get(f"/auth/google/callback?code=abc&state={state}")
    assert response.status_code == 403, response.data
    assert "not permitted" in response.get_json()["error"]
    # A rejected identity creates no user row and no session.
    assert fresh.get("/api/auth/me").get_json()["authenticated"] is False


def test_state_expiry_still_works_server_side(monkeypatch):
    """Attempts older than the TTL are refused regardless of cookie state."""
    state, nonce = _begin()
    # Backdate the DB row so the attempt is stale.
    db = get_db()
    try:
        db.execute(
            "UPDATE oauth_attempts SET started_at = ? WHERE state = ?",
            (int(time.time()) - 10_000, state),
        )
        db.commit()
    finally:
        db.close()

    _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce=nonce)))
    fresh = app.app.test_client(use_cookies=False)
    response = fresh.get(f"/auth/google/callback?code=abc&state={state}")
    assert response.status_code == 400, response.data


def test_missing_state_refused_for_cookieless_client():
    """A callback with no state and no session is still refused."""
    fresh = app.app.test_client(use_cookies=False)
    response = fresh.get("/auth/google/callback?code=abc")
    assert response.status_code == 400, response.data


def test_foreign_nonce_token_refused_for_cookieless_client(monkeypatch):
    """The foreign-nonce defense works identically for cookieless callbacks."""
    state, nonce = _begin()
    _stub_exchange(monkeypatch, _sign(_ATTACKER_KEY, _claims(nonce=nonce)))

    fresh = app.app.test_client(use_cookies=False)
    response = fresh.get(f"/auth/google/callback?code=abc&state={state}")
    assert response.status_code == 401, response.data
