"""Phase B1 - the allowlist store and its admin route.

The allowlist is the thing that stops a publicly reachable server from admitting
every Google account on earth, so it is tested as a security control rather than
as a settings convenience: union semantics, normalisation, fail-closed reads, and
the requirement that only an admin can change it.
"""

import pytest

import app
from app import config
from app.services import auth_service


@pytest.fixture
def client():
    app.init_db()
    return app.app.test_client()


@pytest.fixture(autouse=True)
def clean_stored_allowlist():
    """Never let one test's stored addresses leak into the next.

    `init_db()` runs here as well as in the client fixture: this fixture is
    autouse and therefore runs FIRST, before any test body has had a chance to
    create the schema, and `set_setting` against a database with no `settings`
    table raises OperationalError.
    """
    from app.db import set_setting

    app.init_db()
    set_setting(auth_service.ALLOWLIST_SETTING_KEY, "")
    yield
    set_setting(auth_service.ALLOWLIST_SETTING_KEY, "")


# --------------------------------------------------------------------------- #
# Union semantics
# --------------------------------------------------------------------------- #


class TestEffectiveAllowlist:
    def test_empty_by_default(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH_ALLOWLIST", raising=False)
        assert auth_service.effective_allowlist() == frozenset()

    def test_unions_environment_and_table(self, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "breakglass@example.com")
        auth_service.store_allowlist(["Operator@Example.com"])
        assert auth_service.effective_allowlist() == frozenset({
            "breakglass@example.com",
            "operator@example.com",
        })

    def test_clearing_the_table_keeps_the_break_glass_identity(self, monkeypatch):
        """The environment half exists precisely so this cannot lock you out."""
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "breakglass@example.com")
        auth_service.store_allowlist(["operator@example.com"])
        auth_service.store_allowlist([])
        assert auth_service.effective_allowlist() == frozenset({"breakglass@example.com"})

    def test_storing_never_rewrites_the_environment(self, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "breakglass@example.com")
        auth_service.store_allowlist(["other@example.com"])
        assert config.auth_allowlist() == frozenset({"breakglass@example.com"})


class TestNormalisation:
    def test_lowercases(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH_ALLOWLIST", raising=False)
        auth_service.store_allowlist(["MixedCase@Example.COM"])
        assert auth_service.stored_allowlist() == frozenset({"mixedcase@example.com"})

    def test_drops_blanks_and_whitespace(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH_ALLOWLIST", raising=False)
        auth_service.store_allowlist(["  a@example.com  ", "", "   ", "b@example.com"])
        assert auth_service.stored_allowlist() == frozenset({
            "a@example.com", "b@example.com"
        })

    def test_deduplicates(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH_ALLOWLIST", raising=False)
        auth_service.store_allowlist(["a@example.com", "A@Example.com"])
        assert auth_service.stored_allowlist() == frozenset({"a@example.com"})

    def test_round_trips(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH_ALLOWLIST", raising=False)
        auth_service.store_allowlist(["one@example.com", "two@example.com"])
        assert auth_service.stored_allowlist() == frozenset({
            "one@example.com", "two@example.com"
        })

    def test_accepts_semicolons_and_newlines(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH_ALLOWLIST", raising=False)
        from app.db import set_setting

        set_setting(auth_service.ALLOWLIST_SETTING_KEY, "a@example.com;b@example.com")
        assert auth_service.stored_allowlist() == frozenset({
            "a@example.com", "b@example.com"
        })


# --------------------------------------------------------------------------- #
# is_allowed fails closed
# --------------------------------------------------------------------------- #


class TestIsAllowed:
    def test_denies_when_the_list_is_empty(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH_ALLOWLIST", raising=False)
        assert auth_service.is_allowed("anyone@example.com") is False

    def test_denies_an_absent_email(self, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "a@example.com")
        # A provider that fails to return an e-mail must not yield an anonymous
        # but permitted identity.
        assert auth_service.is_allowed(None) is False
        assert auth_service.is_allowed("") is False

    def test_allows_an_exact_match(self, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "a@example.com")
        assert auth_service.is_allowed("a@example.com") is True

    def test_is_case_insensitive(self, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "a@example.com")
        assert auth_service.is_allowed("A@Example.COM") is True

    def test_does_not_match_on_a_substring(self, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "a@example.com")
        assert auth_service.is_allowed("evil-a@example.com") is False
        assert auth_service.is_allowed("a@example.com.evil.test") is False

    def test_read_failure_denies_rather_than_admits(self, monkeypatch):
        """A database blip must not become an authentication bypass."""
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "")
        monkeypatch.setattr(
            "app.db.get_setting", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("db down"))
        )
        assert auth_service.stored_allowlist() == frozenset()
        assert auth_service.is_allowed("anyone@example.com") is False


# --------------------------------------------------------------------------- #
# The admin route
# --------------------------------------------------------------------------- #


class TestAllowlistRoute:
    def test_get_reports_all_three_sets(self, client, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "breakglass@example.com")
        auth_service.store_allowlist(["operator@example.com"])

        body = client.get("/api/auth/allowlist").get_json()
        assert body["stored"] == ["operator@example.com"]
        assert body["environment"] == ["breakglass@example.com"]
        assert sorted(body["effective"]) == [
            "breakglass@example.com", "operator@example.com"
        ]

    def test_post_replaces_the_stored_list(self, client, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH_ALLOWLIST", raising=False)
        auth_service.store_allowlist(["old@example.com"])

        response = client.post(
            "/api/auth/allowlist", json={"emails": ["New@Example.com"]}
        )
        assert response.status_code == 200
        assert response.get_json()["stored"] == ["new@example.com"]
        assert auth_service.stored_allowlist() == frozenset({"new@example.com"})

    def test_post_rejects_a_non_list(self, client):
        assert client.post(
            "/api/auth/allowlist", json={"emails": "a@example.com"}
        ).status_code == 400

    def test_post_rejects_non_string_entries(self, client):
        assert client.post(
            "/api/auth/allowlist", json={"emails": [123, 456]}
        ).status_code == 400

    def test_post_with_no_key_clears_the_list(self, client, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH_ALLOWLIST", raising=False)
        auth_service.store_allowlist(["a@example.com"])
        response = client.post("/api/auth/allowlist", json={})
        assert response.status_code == 200
        assert response.get_json()["stored"] == []

    def test_route_is_refused_when_enforcement_is_on(self, client, monkeypatch):
        """Admin-only must not mean "open while enforcement is off".

        With enforcement off the decorator is a no-op by design, so this test
        pins what happens once Phase B is live: an unauthenticated caller must
        not be able to enrol themselves.
        """
        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        assert client.get("/api/auth/allowlist").status_code == 401
        assert client.post(
            "/api/auth/allowlist", json={"emails": ["attacker@example.com"]}
        ).status_code == 401

    def test_refused_write_does_not_change_the_list(self, client, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH_ALLOWLIST", raising=False)
        auth_service.store_allowlist(["operator@example.com"])

        monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
        client.post("/api/auth/allowlist", json={"emails": ["attacker@example.com"]})

        assert auth_service.stored_allowlist() == frozenset({"operator@example.com"})

    def test_route_declares_admin(self):
        assert "admin" in app.app.view_functions[
            "api.auth_allowlist_route"
        ].__auth_role__

    def test_uses_a_dedicated_settings_key(self):
        """A generic set-any-key endpoint would make the allowlist decorative."""
        assert auth_service.ALLOWLIST_SETTING_KEY == "auth_allowlist"
        # And it must not collide with the existing storage settings key.
        assert auth_service.ALLOWLIST_SETTING_KEY != "retention_policy"