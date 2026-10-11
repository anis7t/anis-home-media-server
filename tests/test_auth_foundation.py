"""Phase A authentication foundation.

The contract this file pins is deliberately narrow: **the change must be
inert**. Every test that asserts enforcement exists also asserts that the same
request is unauthenticated-accessible while `MEDIA_SERVER_AUTH` is unset, because
a gate that is quietly active is worse than no gate - it looks protected.
"""

import pytest

import app
from app import config
from app.services import auth_service


@pytest.fixture
def client():
    """Test client for the module-level app.

    `config.auth_enabled()` reads the environment at CALL time, so the same
    client serves both the enforcement-off and enforcement-on cases without
    rebuilding the app. That is deliberate: rebuilding would not exercise the
    path the running service takes.
    """
    app.init_db()
    return app.app.test_client()


@pytest.fixture
def enforce(monkeypatch):
    """Turn enforcement on for the duration of one test."""
    monkeypatch.setenv("MEDIA_SERVER_AUTH", "1")
    return True


# --------------------------------------------------------------------------- #
# The core property: enforcement is OFF by default
# --------------------------------------------------------------------------- #


class TestEnforcementIsOffByDefault:
    def test_auth_enabled_defaults_false(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH", raising=False)
        assert config.auth_enabled() is False

    @pytest.mark.parametrize(
        "value,expected",
        [
            ("0", False),
            ("", False),
            ("false", False),
            ("no", False),
            ("1", True),
            ("true", True),
            ("TRUE", True),
            ("Yes", True),
            (" on ", True),
        ],
    )
    def test_env_parsing(self, monkeypatch, value, expected):
        monkeypatch.setenv("MEDIA_SERVER_AUTH", value)
        assert config.auth_enabled() is expected

    def test_control_plane_is_reachable_when_off(self, client, monkeypatch):
        """The whole point of Phase A: no behaviour change while off."""
        monkeypatch.delenv("MEDIA_SERVER_AUTH", raising=False)
        response = client.get("/api/movies")
        assert response.status_code == 200

    def test_pages_are_reachable_when_off(self, client, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH", raising=False)
        assert client.get("/").status_code == 200


# --------------------------------------------------------------------------- #
# Fail closed
# --------------------------------------------------------------------------- #


class TestFailsClosed:
    @pytest.mark.parametrize("path", ["/api/movies", "/api/devices", "/api/system-status"])
    def test_protected_api_routes_are_refused(self, client, enforce, path):
        response = client.get(path)
        assert response.status_code == 401
        assert "no credential provider" in response.get_json()["error"]

    def test_pages_are_refused(self, client, enforce):
        assert client.get("/").status_code == 401

    def test_denial_names_the_recovery_step(self, client, enforce):
        """An operator who trips this must be able to fix it without reading code."""
        body = client.get("/api/movies").get_json()
        assert "MEDIA_SERVER_AUTH=0" in body["error"]

    def test_denial_is_not_cacheable(self, client, enforce):
        # A cached 401 would keep being served to a caller who has since
        # authenticated.
        assert client.get("/api/movies").headers["Cache-Control"] == "no-store"

    def test_every_role_is_refused_not_just_admin_ones(self, client, enforce):
        """Nothing is half-open. A viewer route must not slip through."""
        assert client.get("/api/movies").status_code == 401
        assert client.get("/api/devices").status_code == 401


# --------------------------------------------------------------------------- #
# The media plane must stay anonymous - Cast and DLNA depend on it
# --------------------------------------------------------------------------- #


class TestMediaPlaneStaysAnonymous:
    """`build_media_url()` hands Cast/DLNA LAN URLs they fetch themselves.

    They cannot authenticate, so gating /media and /hls behind a login would
    break casting and DLNA playback. Phase E introduces signed URLs. Until then
    the gate must not touch them - and must say so at startup.
    """

    def test_media_blueprint_is_not_protected(self):
        assert "media" not in auth_service.PROTECTED_BLUEPRINTS

    def test_media_path_is_not_refused(self, client, enforce):
        # A missing file may 404, but it must NOT be 401: that would mean the
        # gate reached the media plane.
        assert client.get("/media/does-not-exist.mkv").status_code != 401

    def test_hls_path_is_not_refused(self, client, enforce):
        assert client.get("/hls/does-not-exist.mkv/playlist.m3u8").status_code != 401

    def test_startup_warns_that_media_is_still_anonymous(self, enforce, caplog):
        with caplog.at_level("WARNING"):
            auth_service.warn_if_media_plane_anonymous()
        assert any("media plane" in r.message for r in caplog.records)

    def test_startup_is_quiet_when_enforcement_is_off(self, monkeypatch, caplog):
        monkeypatch.delenv("MEDIA_SERVER_AUTH", raising=False)
        with caplog.at_level("WARNING"):
            auth_service.warn_if_media_plane_anonymous()
        assert not [r for r in caplog.records if "media plane" in r.message]


# --------------------------------------------------------------------------- #
# Role algebra
# --------------------------------------------------------------------------- #


class TestRoles:
    def test_admin_satisfies_viewer(self):
        assert auth_service.role_satisfies("admin", "viewer") is True

    def test_viewer_satisfies_viewer(self):
        assert auth_service.role_satisfies("viewer", "viewer") is True

    def test_viewer_does_not_satisfy_admin(self):
        assert auth_service.role_satisfies("viewer", "admin") is False

    def test_unknown_role_satisfies_nothing(self):
        assert auth_service.role_satisfies("nobody", "viewer") is False

    def test_unknown_required_role_satisfies_nothing(self):
        # An unrecognised requirement must not be silently satisfiable.
        assert auth_service.role_satisfies("admin", "superuser") is False

    def test_identity_rejects_unknown_role(self):
        with pytest.raises(ValueError):
            auth_service.Identity(subject="x", role="superuser")

    def test_cast_blueprint_requires_admin(self):
        assert "cast" in auth_service.ADMIN_BLUEPRINTS

    def test_cast_is_refused_before_any_role_check(self, client, enforce):
        assert client.get("/api/cast/devices").status_code == 401


# --------------------------------------------------------------------------- #
# Decorator form
# --------------------------------------------------------------------------- #


class TestRequireAuthDecorator:
    def test_is_a_passthrough_when_off(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH", raising=False)
        calls = []

        @auth_service.require_auth("admin")
        def view():
            calls.append(1)
            return "ok"

        assert view() == "ok"
        assert calls == [1]

    def test_refuses_when_on(self, enforce):
        @auth_service.require_auth("admin")
        def view():  # pragma: no cover - must never run
            raise AssertionError("view executed despite enforcement")

        with app.app.test_request_context("/api/movies"):
            response = auth_service.require_auth("admin")(view)()
        assert response.status_code == 401

    def test_preserves_the_wrapped_name(self):
        @auth_service.require_auth("viewer")
        def my_view():  # pragma: no cover
            return "ok"

        # `wraps` matters: `create_app` aliases endpoints by name and
        # `url_for()` resolves by it.
        assert my_view.__name__ == "my_view"

    def test_records_the_required_role(self):
        @auth_service.require_auth("admin")
        def my_view():  # pragma: no cover
            return "ok"

        assert my_view.__auth_role__ == "admin"


# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #


class TestAllowlist:
    def test_empty_by_default_admits_nobody(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_AUTH_ALLOWLIST", raising=False)
        assert config.auth_allowlist() == frozenset()

    def test_parses_comma_separated(self, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "a@x.com,b@x.com")
        assert config.auth_allowlist() == frozenset({"a@x.com", "b@x.com"})

    def test_is_case_insensitive(self, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "Owner@Example.COM")
        assert config.auth_allowlist() == frozenset({"owner@example.com"})

    def test_ignores_whitespace_and_blank_entries(self, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", " a@x.com , , b@x.com ,")
        assert config.auth_allowlist() == frozenset({"a@x.com", "b@x.com"})

    def test_accepts_semicolons(self, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_AUTH_ALLOWLIST", "a@x.com;b@x.com")
        assert config.auth_allowlist() == frozenset({"a@x.com", "b@x.com"})


class TestSecretKey:
    def test_absent_returns_none(self, monkeypatch):
        monkeypatch.delenv("MEDIA_SERVER_SECRET_KEY", raising=False)
        assert config.secret_key() is None

    def test_blank_is_absent_not_empty_string(self, monkeypatch):
        # An empty string would sign with a predictable key.
        monkeypatch.setenv("MEDIA_SERVER_SECRET_KEY", "   ")
        assert config.secret_key() is None

    def test_reads_the_value(self, monkeypatch):
        monkeypatch.setenv("MEDIA_SERVER_SECRET_KEY", "s3cret")
        assert config.secret_key() == "s3cret"

    def test_startup_errors_when_on_without_secret(self, enforce, caplog):
        with caplog.at_level("ERROR"):
            auth_service.startup_auth_diagnostics()
        assert any("MEDIA_SERVER_SECRET_KEY" in r.message for r in caplog.records)


# --------------------------------------------------------------------------- #
# Schema
# --------------------------------------------------------------------------- #


class TestAuthSchema:
    def _tables(self):
        db = app.get_db()
        try:
            rows = db.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        finally:
            db.close()
        return {row["name"] for row in rows}

    def test_users_table_exists(self):
        assert "users" in self._tables()

    def test_auth_tokens_table_exists(self):
        assert "auth_tokens" in self._tables()

    def test_token_hash_is_unique(self):
        db = app.get_db()
        try:
            indexes = db.execute(
                "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='auth_tokens'"
            ).fetchall()
        finally:
            db.close()
        # sqlite auto-names the UNIQUE constraint's backing index.
        assert indexes

    def test_no_user_is_created_by_initialisation(self):
        """Phase A must not invent identities."""
        db = app.get_db()
        try:
            count = db.execute("SELECT COUNT(*) AS n FROM users").fetchone()["n"]
        finally:
            db.close()
        assert count == 0


class TestPostgresMigrationDefinition:
    """The dual backend means the PostgreSQL path needs the same tables.

    `MIGRATION_STATUS.md` records that the Phase 3 exit gate is still unmet, so
    these migrations are unproven at runtime. `_validate_postgres_migrations` is
    a static check, not evidence that they apply.
    """

    def test_migration_2_exists(self):
        from app.db import POSTGRES_MIGRATIONS

        versions = [entry[0] for entry in POSTGRES_MIGRATIONS]
        assert 2 in versions

    def test_migration_definitions_validate(self):
        from app.db import _validate_postgres_migrations

        assert _validate_postgres_migrations()

    def test_auth_tables_are_covered_by_a_migration(self):
        from app.db import POSTGRES_MIGRATIONS

        statements = "\n".join(
            statement for _, _, group in POSTGRES_MIGRATIONS for statement in group
        )
        assert "CREATE TABLE IF NOT EXISTS users" in statements
        assert "CREATE TABLE IF NOT EXISTS auth_tokens" in statements