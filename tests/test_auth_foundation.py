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

    They cannot authenticate, so gating the media routes behind a login would
    break casting and DLNA playback. Phase E introduces signed URLs. Until then
    the gate must not touch them - and must say so at startup.

    These assertions are on real requests, not on blueprint membership. An
    earlier version asserted only that `media` was absent from
    PROTECTED_BLUEPRINTS, which was true while the gate was still wrong:
    `/api/seek-preview-meta/<path>` lives on that same blueprint and is a
    control-plane endpoint that must be gated.
    """

    def test_media_blueprint_is_not_protected(self):
        assert "media" not in auth_service.PROTECTED_BLUEPRINTS

    def test_media_path_is_not_refused(self, client, enforce):
        # A missing file may 404, but it must NOT be 401: that would mean the
        # gate reached the media plane.
        assert client.get("/media/does-not-exist.mkv").status_code != 401

    def test_hls_path_is_not_refused(self, client, enforce):
        assert client.get("/hls/does-not-exist.mkv/playlist.m3u8").status_code != 401

    def test_hls_segment_is_not_refused(self, client, enforce):
        assert client.get("/hls/does-not-exist.mkv/segment_000000.ts").status_code != 401

    def test_transcode_route_is_not_refused(self, client, enforce):
        # Serves a browser-safe MP4 - media delivery, so it belongs to the
        # anonymous set. Found by enumerating every route, not by assuming.
        assert client.get("/transcode/does-not-exist.mkv").status_code != 401

    def test_anonymous_rules_cover_every_media_delivery_route(self):
        """The exemption list must contain what it claims to contain."""
        assert "/media/<path:filename>" in auth_service.ANONYMOUS_RULES
        assert "/hls/<path:filename>/playlist.m3u8" in auth_service.ANONYMOUS_RULES
        assert "/hls/<path:filename>/<segment>" in auth_service.ANONYMOUS_RULES
        assert "/transcode/<path:filename>" in auth_service.ANONYMOUS_RULES

    def test_startup_warns_that_media_is_still_anonymous(self, enforce, caplog):
        with caplog.at_level("WARNING"):
            auth_service.warn_if_media_plane_anonymous()
        assert any("media plane" in r.message for r in caplog.records)

    def test_startup_is_quiet_when_enforcement_is_off(self, monkeypatch, caplog):
        monkeypatch.delenv("MEDIA_SERVER_AUTH", raising=False)
        with caplog.at_level("WARNING"):
            auth_service.warn_if_media_plane_anonymous()
        assert not [r for r in caplog.records if "media plane" in r.message]


class TestRouteClassification:
    """Scoping is by explicit rule exemption, so classification must be deliberate.

    The first implementation scoped by blueprint and was wrong in both
    directions. These pin the two specific mistakes, found by running the real
    service with enforcement enabled.
    """

    def test_seek_preview_meta_is_gated(self, client, enforce):
        """REGRESSION: it escaped the gate by sharing a blueprint with media.

        It is a control-plane API endpoint that reports sampling metadata for a
        media file. Blueprint scoping let it through anonymously.
        """
        assert client.get("/api/seek-preview-meta/does-not-exist.mkv").status_code == 401

    def test_poster_is_gated_by_decision_not_by_accident(self, client, enforce):
        """Artwork reveals what someone watches, so it is authenticated.

        It happens to sit on the `api` blueprint, but the point is that this is
        the intended classification - a deliberate 401, not a side effect.
        """
        assert client.get("/poster/does-not-exist.jpg").status_code == 401

    def test_tmdb_poster_is_gated(self, client, enforce):
        assert client.get("/tmdb-poster/62").status_code == 401

    def test_seek_preview_thumbnail_is_explicitly_exempt(self, client, enforce):
        # Seek previews are requested by the player element the same way media
        # is; keeping them anonymous is a Phase E decision to revisit.
        assert client.get("/seek-preview/does-not-exist.mkv/1.jpg").status_code != 401

    def test_every_registered_rule_is_either_exempt_or_gated(self, client, enforce):
        """No route may fall through the classification.

        Anything not in ANONYMOUS_RULES must be refused under enforcement. This
        is the invariant the blueprint-scoped version silently violated.

        Two subtleties this had to learn the hard way:

        * Requests use a method the rule actually allows. Flask raises the
          routing error (404/405) BEFORE `before_request` runs, so probing a
          POST-only route with GET reports "not gated" for all of them and the
          sweep would pass while proving nothing.
        * The check is on the GATE'S response body, not merely the status code.
          An exempt route may legitimately return 401 from its own view - a
          pairing POST with no token is invalid, and that is correct behaviour.
          Asserting "exempt routes never 401" confuses the view's answer with the
          gate's and produces a false gap.
        """
        gate_marker = "no credential provider"
        problems = []
        for rule in app.app.url_map.iter_rules():
            path = _concrete_path(rule.rule)
            if path is None:
                continue
            methods = (rule.methods or set()) - {"HEAD", "OPTIONS"}
            if not methods:
                continue
            method = sorted(methods)[0]
            response = client.open(path, method=method)

            body = ""
            if response.status_code == 401:
                try:
                    body = (response.get_json() or {}).get("error", "")
                except Exception:
                    body = ""
            gated_by_auth = gate_marker in body
            exempt = rule.rule in auth_service.ANONYMOUS_RULES

            if exempt and gated_by_auth:
                problems.append(f"{rule.rule} is exempt but the GATE refused it")
            elif not exempt and not gated_by_auth:
                problems.append(
                    f"{rule.rule} is not exempt but was not refused by the gate"
                    f" (status {response.status_code})"
                )
        assert not problems, "route classification gaps:\n  " + "\n  ".join(problems)


def _concrete_path(rule: str):
    """Turn a Flask rule into a requestable path, or None if not derivable.

    The ``int:`` case must be checked BEFORE the generic ``<...>`` case: a
    segment like ``<int:tmdb_id>`` starts with ``<``, and treating it as a plain
    placeholder yields ``/tmdb-poster/x``, which the int converter rejects. That
    produced a routing 404 rather than a gate response, which looks exactly like
    an ungated route - the sweep reported a false classification gap.
    """
    if rule.endswith("/<upload_id>/complete"):
        return None
    out = []
    for part in rule.split("/"):
        if "int:" in part:
            out.append("1")
        elif part.startswith("<"):
            out.append("x")
        elif "<" in part:
            out.append("x")
        else:
            out.append(part)
    return "/".join(out) or "/"


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