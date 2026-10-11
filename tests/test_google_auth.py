"""Phase B2 - Google Sign-In.

Two things are being defended here, so both are tested with real cryptography
rather than mocks of the verifier:

  * the ID token's SIGNATURE is checked against a JWKS, so a token forged by
    anyone else is rejected; and
  * the ALLOWLIST is enforced, because the server is reachable from the internet
    and Google Sign-In on its own would admit every Google account on earth.

The Google HTTP endpoints are stubbed; the RSA signing and the verification path
are real. A test that mocked the verifier would assert nothing about the part
that matters.
"""

import base64
import time

import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from joserfc import jwk as jose_jwk
from joserfc import jwt as jose_jwt

import app
from app.services import auth_service, google_auth


# --------------------------------------------------------------------------- #
# Real RSA keys and real signed tokens
# --------------------------------------------------------------------------- #

_GOOGLE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_ATTACKER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _public_jwks(private_key, kid="google-1"):
    numbers = private_key.public_key().public_numbers()

    def b64(value):
        raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")

    return {
        "keys": [
            {"kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256",
             "n": b64(numbers.n), "e": b64(numbers.e)}
        ]
    }


def _sign(private_key, claims, kid="google-1"):
    return jose_jwt.encode(
        {"alg": "RS256", "kid": kid},
        claims,
        jose_jwk.RSAKey.import_key(private_key),
        algorithms=["RS256"],
    )


def _claims(**overrides):
    base = {
        "iss": "https://accounts.google.com",
        "aud": "test-client-id.apps.googleusercontent.com",
        "sub": "100000000000000000001",
        "email": "owner@example.com",
        "email_verified": True,
        "name": "Owner",
        "exp": int(time.time()) + 3600,
        "iat": int(time.time()) - 10,
    }
    base.update(overrides)
    return base


@pytest.fixture(autouse=True)
def google_env(monkeypatch):
    """Configure Google and install a JWKS that serves our test key."""
    monkeypatch.setenv("MEDIA_SERVER_GOOGLE_CLIENT_ID", "test-client-id.apps.googleusercontent.com")
    monkeypatch.setenv("MEDIA_SERVER_GOOGLE_CLIENT_SECRET", "test-secret")
    monkeypatch.setenv("MEDIA_SERVER_SECRET_KEY", "unit-test-secret-key")
    monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "owner@example.com")

    # `create_app()` reads the signing key once, at import time. In production
    # that is correct - NSSM supplies it before the process starts. Here the env
    # arrives after import, so the attribute is set directly rather than relying
    # on import-time environment, which AGENTS.md forbids.
    app.app.secret_key = "unit-test-secret-key"

    google_auth.reset_jwks_cache()
    monkeypatch.setattr(
        google_auth, "_load_jwks", lambda *a, **k: _public_jwks(_GOOGLE_KEY)
    )
    app.init_db()
    yield
    google_auth.reset_jwks_cache()


@pytest.fixture
def client():
    return app.app.test_client()


@pytest.fixture
def allowlist_clear(monkeypatch):
    monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "")
    return True


# --------------------------------------------------------------------------- #
# Signature verification - the real thing
# --------------------------------------------------------------------------- #


class TestIdTokenVerification:
    def test_accepts_a_genuinely_signed_token(self):
        claims = google_auth.verify_id_token(_sign(_GOOGLE_KEY, _claims()), nonce=None)
        assert claims["email"] == "owner@example.com"

    def test_rejects_a_token_signed_by_another_key(self):
        forged = _sign(_ATTACKER_KEY, _claims())
        with pytest.raises(Exception):
            google_auth.verify_id_token(forged, nonce=None)

    def test_rejects_an_unknown_kid(self):
        with pytest.raises(Exception):
            google_auth.verify_id_token(_sign(_GOOGLE_KEY, _claims(), kid="nope"), nonce=None)

    def test_rejects_another_audience(self):
        token = _sign(_GOOGLE_KEY, _claims(aud="someone-else.apps.googleusercontent.com"))
        with pytest.raises(RuntimeError, match="audience"):
            google_auth.verify_id_token(token, nonce=None)

    def test_rejects_a_foreign_issuer(self):
        token = _sign(_GOOGLE_KEY, _claims(iss="https://evil.example"))
        with pytest.raises(RuntimeError, match="issuer"):
            google_auth.verify_id_token(token, nonce=None)

    def test_rejects_an_expired_token(self):
        token = _sign(_GOOGLE_KEY, _claims(exp=int(time.time()) - 10))
        with pytest.raises(RuntimeError, match="expired"):
            google_auth.verify_id_token(token, nonce=None)

    def test_rejects_a_nonce_mismatch(self):
        token = _sign(_GOOGLE_KEY, _claims(nonce="other"))
        with pytest.raises(RuntimeError, match="nonce"):
            google_auth.verify_id_token(token, nonce="expected")

    def test_rejects_a_token_with_no_email(self):
        claims = _claims()
        claims.pop("email")
        with pytest.raises(RuntimeError, match="no e-mail"):
            google_auth.verify_id_token(_sign(_GOOGLE_KEY, claims), nonce=None)


# --------------------------------------------------------------------------- #
# PKCE
# --------------------------------------------------------------------------- #


class TestPkce:
    def test_verifier_and_challenge_differ(self):
        verifier, challenge = google_auth.pkce_pair()
        assert verifier != challenge

    def test_challenge_is_s256_of_the_verifier(self):
        import hashlib

        verifier, challenge = google_auth.pkce_pair()
        expected = base64.urlsafe_b64encode(
            hashlib.sha256(verifier.encode("ascii")).digest()
        ).decode().rstrip("=")
        assert challenge == expected

    def test_each_call_makes_a_new_verifier(self):
        assert google_auth.pkce_pair()[0] != google_auth.pkce_pair()[0]


# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #


class TestConfiguration:
    def test_is_configured_when_complete(self):
        assert google_auth.is_configured() is True

    def test_missing_client_id_is_reported(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_GOOGLE_CLIENT_ID", raising=False)
        assert any("CLIENT_ID" in p for p in google_auth.configuration_problems())

    def test_missing_secret_is_reported(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_GOOGLE_CLIENT_SECRET", raising=False)
        assert any("CLIENT_SECRET" in p for p in google_auth.configuration_problems())

    def test_missing_signing_key_is_reported(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_SECRET_KEY", raising=False)
        # Without it a session would be unsigned, i.e. forgeable.
        assert any("SECRET_KEY" in p for p in google_auth.configuration_problems())

    def test_start_route_refuses_when_unconfigured(self, client, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_GOOGLE_CLIENT_ID", raising=False)
        response = client.get("/auth/google")
        assert response.status_code == 503


# --------------------------------------------------------------------------- #
# The authorization request
# --------------------------------------------------------------------------- #


class TestAuthorizeRequest:
    def test_redirects_to_google(self, client):
        response = client.get("/auth/google")
        assert response.status_code == 302
        assert response.headers["Location"].startswith(
            "https://accounts.google.com/o/oauth2/v2/auth"
        )

    def test_carries_state_nonce_and_pkce(self, client):
        location = client.get("/auth/google").headers["Location"]
        assert "code_challenge_method=S256" in location
        assert "state=" in location
        assert "nonce=" in location

    def test_requests_only_openid_email_profile(self, client):
        location = client.get("/auth/google").headers["Location"]
        # No Drive, no Gmail - this server has no business asking for them.
        assert "scope=openid+email+profile" in location
        assert "drive" not in location.lower()


# --------------------------------------------------------------------------- #
# The callback - where trust is established
# --------------------------------------------------------------------------- #


def _stub_exchange(monkeypatch, id_token):
    monkeypatch.setattr(
        google_auth,
        "exchange_code",
        lambda code, redirect_uri, verifier: {"id_token": id_token},
    )


def _begin(client):
    """Start a sign-in and return the Location so state/nonce can be read."""
    location = client.get("/auth/google").headers["Location"]
    from urllib.parse import parse_qs, urlparse

    query = parse_qs(urlparse(location).query)
    return query["state"][0], query["nonce"][0]


class TestCallbackRejections:
    def test_missing_state_is_refused(self, client, monkeypatch):
        _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims()))
        assert client.get("/auth/google/callback?code=abc").status_code == 400

    def test_state_mismatch_is_refused(self, client, monkeypatch):
        _begin(client)
        _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims()))
        response = client.get("/auth/google/callback?code=abc&state=wrong")
        assert response.status_code == 400
        assert "state mismatch" in response.get_json()["error"]

    def test_expired_attempt_is_refused(self, client, monkeypatch):
        import app as app_module
        from flask import session as flask_session

        state, nonce = _begin(client)
        with client.session_transaction() as sess:
            sess[f"_oauth_state_at"] = int(time.time()) - 10_000
        _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims()))
        response = client.get(f"/auth/google/callback?code=abc&state={state}")
        assert response.status_code == 400
        assert "expired" in response.get_json()["error"]

    def test_google_error_is_reported(self, client):
        assert client.get(
            "/auth/google/callback?error=access_denied&state=x"
        ).status_code == 400

    def test_forged_token_is_refused(self, client, monkeypatch):
        state, nonce = _begin(client)
        _stub_exchange(monkeypatch, _sign(_ATTACKER_KEY, _claims(nonce=nonce)))
        response = client.get(f"/auth/google/callback?code=abc&state={state}")
        assert response.status_code == 401

    def test_nonce_mismatch_is_refused(self, client, monkeypatch):
        state, nonce = _begin(client)
        _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce="something-else")))
        response = client.get(f"/auth/google/callback?code=abc&state={state}")
        assert response.status_code == 401

    def test_unverified_email_is_refused(self, client, monkeypatch):
        state, nonce = _begin(client)
        _stub_exchange(
            monkeypatch,
            _sign(_GOOGLE_KEY, _claims(email="owner@example.com", email_verified=False, nonce=nonce)),
        )
        response = client.get(f"/auth/google/callback?code=abc&state={state}")
        assert response.status_code == 403


class TestAllowlistEnforcement:
    """The control the whole design exists for."""

    def test_unlisted_identity_is_refused(self, client, monkeypatch):
        state, nonce = _begin(client)
        _stub_exchange(
            monkeypatch,
            _sign(_GOOGLE_KEY, _claims(email="stranger@example.com", nonce=nonce)),
        )
        response = client.get(f"/auth/google/callback?code=abc&state={state}")
        assert response.status_code == 403
        assert "not permitted" in response.get_json()["error"]

    def test_unlisted_identity_creates_no_user_row(self, client, monkeypatch):
        """The row must not exist even after a fully verified exchange."""
        from app.db import get_db

        state, nonce = _begin(client)
        _stub_exchange(
            monkeypatch,
            _sign(_GOOGLE_KEY, _claims(email="stranger@example.com", nonce=nonce)),
        )
        client.get(f"/auth/google/callback?code=abc&state={state}")

        db = get_db()
        try:
            rows = db.execute(
                "SELECT email FROM users WHERE email=?", ("stranger@example.com",)
            ).fetchall()
        finally:
            db.close()
        assert rows == []

    def test_rejection_does_not_establish_a_session(self, client, monkeypatch):
        state, nonce = _begin(client)
        _stub_exchange(
            monkeypatch,
            _sign(_GOOGLE_KEY, _claims(email="stranger@example.com", nonce=nonce)),
        )
        client.get(f"/auth/google/callback?code=abc&state={state}")
        assert client.get("/api/auth/me").get_json()["authenticated"] is False

    def test_empty_allowlist_admits_nobody(self, client, monkeypatch, allowlist_clear):
        state, nonce = _begin(client)
        _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce=nonce)))
        response = client.get(f"/auth/google/callback?code=abc&state={state}")
        assert response.status_code == 403

    def test_rejection_message_does_not_confirm_whether_the_account_exists(self, client, monkeypatch):
        state, nonce = _begin(client)
        _stub_exchange(
            monkeypatch,
            _sign(_GOOGLE_KEY, _claims(email="stranger@example.com", nonce=nonce)),
        )
        body = client.get(f"/auth/google/callback?code=abc&state={state}").get_json()
        # Must not enumerate accounts.
        assert "stranger@example.com" not in body["error"]


class TestSuccessfulSignIn:
    def test_creates_a_user_and_a_session(self, client, monkeypatch):
        state, nonce = _begin(client)
        _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce=nonce)))

        response = client.get(f"/auth/google/callback?code=abc&state={state}")
        assert response.status_code == 302

        me = client.get("/api/auth/me").get_json()
        assert me["authenticated"] is True
        assert me["email"] == "owner@example.com"

    def test_new_user_defaults_to_viewer(self, client, monkeypatch):
        state, nonce = _begin(client)
        _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce=nonce)))
        client.get(f"/auth/google/callback?code=abc&state={state}")
        assert client.get("/api/auth/me").get_json()["role"] == "viewer"

    def test_second_sign_in_reuses_the_same_row(self, client, monkeypatch):
        for _ in range(2):
            state, nonce = _begin(client)
            _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce=nonce)))
            client.get(f"/auth/google/callback?code=abc&state={state}")

        from app.db import get_db

        db = get_db()
        try:
            # Scoped to this test's identity, not a global count: another test
            # module may legitimately have left a user row behind in the shared
            # test database, and asserting on the total made this an
            # order-dependent landmine.
            count = db.execute(
                "SELECT COUNT(*) AS n FROM users WHERE email=?", ("owner@example.com",)
            ).fetchone()["n"]
        finally:
            db.close()
        assert count == 1

    def test_next_cannot_redirect_off_site(self, client, monkeypatch):
        state, nonce = _begin(client)
        _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce=nonce)))
        response = client.get(
            f"/auth/google/callback?code=abc&state={state}&next=https://evil.example/"
        )
        assert response.status_code == 302
        assert "evil.example" not in response.headers["Location"]

    def test_protocol_relative_next_is_refused(self, client, monkeypatch):
        state, nonce = _begin(client)
        _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce=nonce)))
        response = client.get(f"/auth/google/callback?code=abc&state={state}&next=//evil.example")
        assert "evil.example" not in response.headers["Location"]


class TestLogout:
    def test_logout_clears_the_session(self, client, monkeypatch):
        state, nonce = _begin(client)
        _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce=nonce)))
        client.get(f"/auth/google/callback?code=abc&state={state}")
        assert client.get("/api/auth/me").get_json()["authenticated"] is True

        client.post("/auth/logout")
        assert client.get("/api/auth/me").get_json()["authenticated"] is False


class TestEnforcementIntegration:
    """With enforcement on, the session must actually satisfy the gate."""

    def test_session_unlocks_protected_routes(self, client, monkeypatch):
        state, nonce = _begin(client)
        _stub_exchange(monkeypatch, _sign(_GOOGLE_KEY, _claims(nonce=nonce)))
        client.get(f"/auth/google/callback?code=abc&state={state}")

        # Same client, same cookie jar: now switch enforcement on.
        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        assert client.get("/api/movies").status_code == 200

    def test_no_session_still_gets_401(self, client, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        assert client.get("/api/movies").status_code == 401

    def test_sign_in_itself_stays_reachable_under_enforcement(self, client, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        # Otherwise there would be no way to sign in at all.
        assert client.get("/auth/google").status_code == 302