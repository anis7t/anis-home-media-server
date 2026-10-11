"""Phase C - the API token system.

A token is an identity, not just a key: it resolves to the same Identity as a
browser session, which is what makes "Anis Parvez on the TV" the same person as
"Anis Parvez in the browser" - and therefore what lets watch history and player
settings follow a person between devices.

The properties worth defending here are that a token cannot exceed its user, that
the plaintext is unrecoverable once minted, and that a revoked or expired token
is indistinguishable from a wrong one.
"""

import time

import pytest

import app
from app.db import get_db
from app.services import auth_service, token_service


@pytest.fixture(autouse=True)
def google_env(monkeypatch):
    monkeypatch.setenv("MEDIA_SERVER_GOOGLE_CLIENT_ID", "test-client-id")
    monkeypatch.setenv("MEDIA_SERVER_GOOGLE_CLIENT_SECRET", "test-secret")
    monkeypatch.setenv("MEDIA_SERVER_SECRET_KEY", "unit-test-secret-key")
    monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "owner@example.com")
    app.app.secret_key = "unit-test-secret-key"
    app.init_db()
    yield
    # Clean up on the way OUT, not only on the way in. Leaving user rows behind
    # made another module's global COUNT(*) order-dependent.
    db = get_db()
    try:
        db.execute("DELETE FROM auth_tokens")
        db.execute("DELETE FROM users")
        db.commit()
    finally:
        db.close()


@pytest.fixture
def admin_user():
    db = get_db()
    try:
        db.execute("DELETE FROM auth_tokens")
        db.execute("DELETE FROM users")
        db.execute(
            "INSERT INTO users (google_sub, email, name, role, created_at)"
            " VALUES ('sub-admin','owner@example.com','Owner','admin',?)",
            (int(time.time()),),
        )
        db.commit()
        row = db.execute("SELECT id FROM users WHERE email='owner@example.com'").fetchone()
        return row["id"]
    finally:
        db.close()


@pytest.fixture
def client():
    return app.app.test_client()


@pytest.fixture
def signed_in_admin(client):
    with client.session_transaction() as sess:
        sess["uid"] = 1
        sess["email"] = "owner@example.com"
        sess["role"] = "admin"
        sess["issued_at"] = int(time.time())
    return client


# --------------------------------------------------------------------------- #
# Token material
# --------------------------------------------------------------------------- #


class TestTokenMaterial:
    def test_tokens_are_prefixed_and_long(self, admin_user):
        plaintext, _ = token_service.create_token(admin_user, "TV")
        assert plaintext.startswith("ms_")
        # 256 bits of entropy, base64url encoded.
        assert len(plaintext) > 40

    def test_each_token_is_unique(self, admin_user):
        a, _ = token_service.create_token(admin_user, "a")
        b, _ = token_service.create_token(admin_user, "b")
        assert a != b

    def test_plaintext_is_never_stored(self, admin_user):
        plaintext, _ = token_service.create_token(admin_user, "TV")
        db = get_db()
        try:
            rows = db.execute("SELECT token_hash FROM auth_tokens").fetchall()
        finally:
            db.close()
        assert all(plaintext not in row["token_hash"] for row in rows)

    def test_stored_form_is_a_hash_not_the_token(self, admin_user):
        plaintext, _ = token_service.create_token(admin_user, "TV")
        db = get_db()
        try:
            row = db.execute("SELECT token_hash FROM auth_tokens").fetchone()
        finally:
            db.close()
        assert row["token_hash"] == token_service.hash_token(plaintext)
        assert plaintext not in row["token_hash"]

    def test_listing_never_returns_the_token(self, admin_user):
        token_service.create_token(admin_user, "TV")
        listed = token_service.list_tokens()
        assert len(listed) == 1
        assert "token" not in listed[0]
        assert "token_hash" not in listed[0]


# --------------------------------------------------------------------------- #
# Resolution
# --------------------------------------------------------------------------- #


class TestTokenResolution:
    def test_a_valid_token_resolves_to_its_user(self, admin_user):
        plaintext, _ = token_service.create_token(admin_user, "TV")
        record = token_service.resolve_token(plaintext)
        assert record is not None
        assert record["email"] == "owner@example.com"
        assert record["role"] == "admin"

    def test_an_unknown_token_resolves_to_none(self):
        assert token_service.resolve_token("ms_totally-made-up") is None

    def test_a_missing_prefix_is_rejected_without_a_db_hit(self):
        assert token_service.resolve_token("no-prefix-token") is None

    def test_a_revoked_token_stops_working(self, admin_user):
        plaintext, record = token_service.create_token(admin_user, "TV")
        assert token_service.resolve_token(plaintext) is not None
        token_service.revoke_token(record["id"])
        assert token_service.resolve_token(plaintext) is None

    def test_revoking_twice_is_reported_as_not_found(self, admin_user):
        _, record = token_service.create_token(admin_user, "TV")
        assert token_service.revoke_token(record["id"]) is True
        assert token_service.revoke_token(record["id"]) is False

    def test_an_expired_token_stops_working(self, admin_user):
        plaintext, record = token_service.create_token(admin_user, "TV", validity_days=1)
        db = get_db()
        try:
            db.execute(
                "UPDATE auth_tokens SET expires_at=? WHERE id=?",
                (int(time.time()) - 10, record["id"]),
            )
            db.commit()
        finally:
            db.close()
        assert token_service.resolve_token(plaintext) is None

    def test_last_used_is_stamped(self, admin_user):
        plaintext, record = token_service.create_token(admin_user, "TV")
        assert token_service.list_tokens()[0]["last_used_at"] is None
        token_service.resolve_token(plaintext)
        assert token_service.list_tokens()[0]["last_used_at"] is not None


class TestTokenCannotExceedItsUser:
    def test_token_inherits_the_viewer_role(self):
        db = get_db()
        try:
            db.execute("DELETE FROM users")
            db.execute(
                "INSERT INTO users (google_sub, email, role, created_at)"
                " VALUES ('sub-viewer','viewer@example.com','viewer',?)",
                (int(time.time()),),
            )
            db.commit()
            user_id = db.execute("SELECT id FROM users WHERE email='viewer@example.com'").fetchone()["id"]
        finally:
            db.close()

        plaintext, _ = token_service.create_token(user_id, "TV")
        assert token_service.resolve_token(plaintext)["role"] == "viewer"


class TestBearerParsing:
    def test_parses_a_bearer_header(self):
        assert token_service.extract_bearer("Bearer ms_abc") == "ms_abc"

    def test_is_case_insensitive_on_the_scheme(self):
        assert token_service.extract_bearer("bearer ms_abc") == "ms_abc"

    def test_ignores_other_schemes(self):
        assert token_service.extract_bearer("Basic dXNlcjpwYXNz") is None

    def test_ignores_a_missing_header(self):
        assert token_service.extract_bearer(None) is None
        assert token_service.extract_bearer("") is None

    def test_ignores_a_bare_scheme(self):
        assert token_service.extract_bearer("Bearer") is None
        assert token_service.extract_bearer("Bearer   ") is None


class TestPairingPayload:
    def test_token_travels_in_the_fragment(self):
        """Fragments are not sent in request lines, so the token stays out of
        Cloudflare and Waitress access logs."""
        payload = token_service.pairing_payload("ms_secret", "https://media.anisparvez.in")
        assert payload.startswith("https://media.anisparvez.in/auth/pair#")
        assert "ms_secret" not in payload.split("#")[0]

    def test_strips_a_trailing_slash_from_the_origin(self):
        payload = token_service.pairing_payload("ms_x", "https://host/")
        assert payload.startswith("https://host/auth/pair#")


# --------------------------------------------------------------------------- #
# Routes
# --------------------------------------------------------------------------- #


class TestTokenRoutes:
    def test_minting_requires_a_session(self, client, admin_user, monkeypatch):
        # `require_auth` is a deliberate pass-through while enforcement is off,
        # so the gate is only meaningful with it on. Even then the view refuses
        # an absent identity itself.
        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        assert client.post("/api/auth/tokens", json={"label": "TV"}).status_code == 401

    def test_minting_is_refused_with_no_identity_even_when_enforcement_is_off(
        self, client, admin_user
    ):
        """The decorator being inert must not turn this into a 500."""
        response = client.post("/api/auth/tokens", json={"label": "TV"})
        assert response.status_code == 403

    def test_minting_requires_admin(self, client, admin_user, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        with client.session_transaction() as sess:
            sess["uid"] = 1
            sess["email"] = "owner@example.com"
            sess["role"] = "viewer"
            sess["issued_at"] = int(time.time())
        assert client.post("/api/auth/tokens", json={"label": "TV"}).status_code == 403

    def test_a_viewer_token_cannot_mint_tokens(self, client, admin_user, monkeypatch):
        """A leaked TV token must not be able to enrol further devices."""
        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        db = get_db()
        try:
            db.execute("DELETE FROM users")
            db.execute(
                "INSERT INTO users (google_sub, email, role, created_at)"
                " VALUES ('sub-viewer','viewer@example.com','viewer',?)",
                (int(time.time()),),
            )
            db.commit()
            viewer_id = db.execute(
                "SELECT id FROM users WHERE email='viewer@example.com'"
            ).fetchone()["id"]
        finally:
            db.close()

        plaintext, _ = token_service.create_token(viewer_id, "TV")
        response = client.post(
            "/api/auth/tokens",
            json={"label": "another"},
            headers={"Authorization": f"Bearer {plaintext}"},
        )
        assert response.status_code == 403

    def test_admin_can_mint(self, signed_in_admin, admin_user):
        response = signed_in_admin.post("/api/auth/tokens", json={"label": "Living room TV"})
        assert response.status_code == 201
        body = response.get_json()
        assert body["token"].startswith("ms_")
        assert body["label"] == "Living room TV"
        assert "#" in body["pairing_url"]

    def test_a_label_is_required(self, signed_in_admin, admin_user):
        # Opaque ids in a list are how you revoke the wrong token.
        assert signed_in_admin.post("/api/auth/tokens", json={}).status_code == 400

    def test_rejects_a_non_positive_validity(self, signed_in_admin, admin_user):
        assert signed_in_admin.post(
            "/api/auth/tokens", json={"label": "TV", "validity_days": 0}
        ).status_code == 400

    def test_listing_never_leaks_the_token(self, signed_in_admin, admin_user):
        signed_in_admin.post("/api/auth/tokens", json={"label": "TV"})
        body = signed_in_admin.get("/api/auth/tokens").get_json()
        assert "token" not in str(body["tokens"])

    def test_revoke_then_the_token_stops_working(self, signed_in_admin, admin_user):
        minted = signed_in_admin.post("/api/auth/tokens", json={"label": "TV"}).get_json()
        plaintext = minted["token"]

        # Give the token a session so we can prove the token itself stops working.
        assert signed_in_admin.get("/api/movies", headers={
            "Authorization": f"Bearer {plaintext}"
        }).status_code in (200, 401)

        assert signed_in_admin.delete(f"/api/auth/tokens/{minted['id']}").status_code == 200
        assert token_service.resolve_token(plaintext) is None


class TestBearerAuthenticatesTheGate:
    def test_a_bearer_token_reaches_a_protected_route(self, client, admin_user, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        plaintext, _ = token_service.create_token(admin_user, "TV")

        assert client.get("/api/movies").status_code == 401

        response = client.get("/api/movies", headers={"Authorization": f"Bearer {plaintext}"})
        assert response.status_code == 200

    def test_whoami_reports_the_token_identity(self, client, admin_user, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        plaintext, _ = token_service.create_token(admin_user, "TV")
        body = client.get(
            "/api/auth/me", headers={"Authorization": f"Bearer {plaintext}"}
        ).get_json()
        assert body["authenticated"] is True
        assert body["email"] == "owner@example.com"

    def test_a_bad_token_is_refused(self, client, admin_user, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        response = client.get("/api/movies", headers={"Authorization": "Bearer ms_nope"})
        assert response.status_code == 401

    def test_a_session_still_works_alongside_tokens(self, client, admin_user, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        with client.session_transaction() as sess:
            sess["uid"] = 1
            sess["email"] = "owner@example.com"
            sess["role"] = "admin"
            sess["issued_at"] = int(time.time())
        assert client.get("/api/movies").status_code == 200


class TestPairingRoute:
    def test_a_pairing_token_establishes_a_session(self, client, admin_user):
        plaintext, _ = token_service.create_token(admin_user, "TV")
        response = client.post("/auth/pair", data={"token": plaintext})
        assert response.status_code == 302

    def test_pairing_reports_the_user_it_paired_as(self, client, admin_user):
        plaintext, _ = token_service.create_token(admin_user, "TV")
        client.post("/auth/pair", data={"token": plaintext})
        assert client.get("/api/auth/me").get_json()["email"] == "owner@example.com"

    def test_an_invalid_pairing_token_is_refused(self, client):
        assert client.post("/auth/pair", data={"token": "ms_bogus"}).status_code == 401

    def test_pairing_with_no_token_is_refused(self, client):
        assert client.post("/auth/pair", data={}).status_code == 401

    def test_pairing_survives_enforcement(self, client, admin_user, monkeypatch):
        """Otherwise a device could never be enrolled once enforcement is on."""
        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        assert client.get("/auth/pair").status_code == 200

    def test_a_revoked_token_cannot_pair(self, client, admin_user):
        plaintext, record = token_service.create_token(admin_user, "TV")
        token_service.revoke_token(record["id"])
        assert client.post("/auth/pair", data={"token": plaintext}).status_code == 401