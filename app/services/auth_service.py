"""Authentication primitives - Phase A (foundation only).

WHAT THIS PHASE DELIBERATELY DOES NOT DO
---------------------------------------
There is no credential provider yet. Google Sign-In lands in Phase B and the API
token system in Phase C. This module exists to install the gate, prove it is
inert while `MEDIA_SERVER_AUTH` is off, and fail CLOSED if it is switched on
before a provider exists.

That fail-closed behaviour is the important property. A partially enabled
authentication system that quietly allows anonymous access to
`/api/media/delete` would be worse than no authentication at all, because it
would look protected. So:

  * enforcement off  -> every protected route behaves exactly as before;
  * enforcement on, no provider -> 401 everywhere, with a message naming the
    recovery step.

Per-route role mapping (admin-only for delete / storage / scan / upload /
devices / cast) is Phase B work. It is safe to defer because the fail-closed
path means the destructive routes are unreachable rather than over-permissive
until a provider exists.

The media plane (`/media`, `/hls`, `/transcode`) is NOT gated, and neither is
`/api/seek-preview-meta` - see ANONYMOUS_RULES for why the exemption list is
explicit rather than blueprint-derived. Cast and DLNA receivers fetch the media
routes themselves and cannot authenticate. Phase E introduces short-lived signed
URLs, and it is also where the seek-preview route gets its own decision.
`warn_if_media_plane_anonymous()` surfaces the gap loudly at startup instead of
leaving it to be discovered.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from functools import wraps
from typing import Callable, Optional

from flask import Response, jsonify, request

from app import config

log = logging.getLogger(__name__)

#: Routes that MUST stay anonymous so Cast and DLNA receivers keep working.
#:
#: `build_media_url()` (`app/services/cast_service.py:287`) hands these devices a
#: URL on the LAN address which they fetch themselves. A Samsung TV reading a
#: DIDL-Lite `<res>` URL, or a Cast receiver running its own loader, cannot
#: complete an OAuth redirect, hold a session cookie, or set an Authorization
#: header. Gating these is the one way to break casting and DLNA playback.
#:
#: This list is deliberately EXPLICIT rather than derived from blueprint
#: membership. The first implementation scoped by blueprint name, and that was
#: wrong in both directions: it gated `/poster/<path>` and `/tmdb-poster/<int>`
#: (registered on the `api` blueprint) purely because of where they live, while
#: `/api/seek-preview-meta/<path>` - a genuine control-plane endpoint - escaped
#: the gate entirely because it shares a blueprint with media delivery. Both
#: were found by running the real service with enforcement on; the unit tests
#: could not see them, because they only asserted blueprint membership.
#:
#: Adding a new media-delivery route means adding it here.
ANONYMOUS_RULES = frozenset({
    # Byte-range direct play.
    "/media/<path:filename>",
    # HLS master playlist and segments.
    "/hls/<path:filename>/playlist.m3u8",
    "/hls/<path:filename>/<segment>",
    # Browser-safe MP4 with byte range support - also media delivery.
    "/transcode/<path:filename>",
    # Seek-preview thumbnails are fetched by the player element the same way
    # media is, so they travel on the same anonymous path.
    "/seek-preview/<path:filename>/<thumb>",
    # Sign-in itself. Listed as exact rules, never as an "/auth/*" prefix: a
    # prefix would silently exempt anything ever added under that namespace.
    "/auth/google",
    "/auth/google/callback",
    "/auth/logout",
    "/auth/pair",
    "/api/auth/me",
})

#: Blueprints whose routes require a credential once enforcement is on.
#: Retained for the role lookup and documentation; scoping itself is by rule
#: (see ANONYMOUS_RULES), which is finer-grained and explicit.
PROTECTED_BLUEPRINTS = frozenset({"api", "cast", "pages", "subtitles"})

#: Blueprints that additionally require the `admin` role.
ADMIN_BLUEPRINTS = frozenset({"cast"})

ROLE_VIEWER = "viewer"
ROLE_ADMIN = "admin"
_ROLES = {ROLE_VIEWER, ROLE_ADMIN}

_ROLE_RANK = {ROLE_VIEWER: 1, ROLE_ADMIN: 2}


@dataclass(frozen=True)
class Identity:
    """An authenticated caller. Replaced in Phase B/C by the real resolver."""

    subject: str
    role: str = ROLE_VIEWER

    def __post_init__(self) -> None:
        if self.role not in _ROLES:
            raise ValueError(f"Unknown role {self.role!r}; expected one of {sorted(_ROLES)}")


def role_satisfies(actual: str, required: str) -> bool:
    """True when *actual* is at least as privileged as *required*."""
    return _ROLE_RANK.get(actual, 0) >= _ROLE_RANK.get(required, 99)


def resolve_identity() -> Optional[Identity]:
    """Return the caller's identity, or None.

    Two credential classes resolve to the SAME Identity type, which is what lets
    one signed-in person be one person across the browser, the phone and the TV:

      1. our own signed session cookie, issued at the Google callback
         (`google_auth.issue_session()`); then
      2. `Authorization: Bearer <token>` for clients that cannot do a browser
         redirect - the Flutter/Fire TV app (`token_service`).

    The Google ID token is never stored anywhere: it expires in about an hour
    and it is a third-party credential.

    A token's role comes from its user, so a token can never exceed the person
    who issued it.

    Returns None when there is no credential, when it is unknown, revoked or
    expired, or when the session has aged out - all of which fail closed.
    """
    try:
        from app.services import google_auth
        identity = google_auth.session_identity()
        if identity is not None:
            return identity
    except Exception:  # pragma: no cover - a broken session must not 500
        log.exception("AUTH: session could not be read")

    try:
        from app.services import token_service

        token = token_service.extract_bearer(request.headers.get("Authorization"))
        if not token:
            return None
        record = token_service.resolve_token(token)
        if record is None:
            return None
        return Identity(
            subject=record["email"],
            role=record["role"],
        )
    except Exception:  # pragma: no cover - a broken token must not 500
        log.exception("AUTH: bearer token could not be resolved")
        return None


# --------------------------------------------------------------------------- #
# Allowlist store (Phase B1)
#
# The allowlist lives in the `settings` table so addresses can be added without
# a service restart, and the environment variable is kept as a break-glass
# administrator. The EFFECTIVE list is the union of the two: the table is
# reachable by anyone who can load the web UI, the environment variable only by
# someone with machine access, so unioning means clearing the table by accident
# cannot lock the operator out.
# --------------------------------------------------------------------------- #

#: `settings` key holding the operator-managed allowlist.
ALLOWLIST_SETTING_KEY = "auth_allowlist"


def _split_emails(raw) -> frozenset:
    parts = str(raw or "").replace(";", ",").replace("\n", ",").split(",")
    return frozenset(part.strip().lower() for part in parts if part.strip())


def stored_allowlist() -> frozenset:
    """The allowlist held in the `settings` table.

    A read failure must not silently widen access, so it falls back to "nobody"
    and logs. Failing open here would turn a database blip into an
    authentication bypass.
    """
    from app.db import get_setting

    try:
        raw = get_setting(ALLOWLIST_SETTING_KEY, "") or ""
    except Exception:  # pragma: no cover - defensive; the table always exists
        log.exception("AUTH: could not read the stored allowlist")
        return frozenset()
    return _split_emails(raw)


def effective_allowlist() -> frozenset:
    """Addresses allowed to sign in: the UNION of the table and the environment."""
    return config.auth_allowlist() | stored_allowlist()


def store_allowlist(emails) -> frozenset:
    """Replace the stored allowlist; returns the normalised set.

    The environment half of the effective list is deliberately NOT rewritten -
    it is the break-glass identity and is not ours to remove.
    """
    from app.db import set_setting

    normalised = frozenset(
        str(email).strip().lower() for email in emails if str(email).strip()
    )
    set_setting(ALLOWLIST_SETTING_KEY, ", ".join(sorted(normalised)))
    return normalised


def is_allowed(email) -> bool:
    """Whether *email* may authenticate. Case-insensitive, fails closed.

    An absent or empty address is never allowed, so a provider that fails to
    return an e-mail fails closed rather than admitting an anonymous identity.
    """
    if not email:
        return False
    return str(email).strip().lower() in effective_allowlist()


_PROVIDER_MISSING = (
    "Authentication is enabled but no credential provider is configured. "
    "This is the Phase A foundation, which installs the gate without "
    "enforcing it: Google Sign-In is Phase B and API tokens are Phase C. "
    "Set MEDIA_SERVER_AUTH=0 in the service environment to restore access."
)


def _deny(status: int, message: str) -> Response:
    response = jsonify({"error": message})
    response.status_code = status
    # Never let an intermediary cache a denial for a route that may later be
    # reachable to an authenticated caller.
    response.headers["Cache-Control"] = "no-store"
    return response


def _reject_anonymous() -> Response:
    return _deny(401, _PROVIDER_MISSING)


def current_rule() -> Optional[str]:
    """The Flask rule string for the matched route, or None.

    `request.url_rule` is None only when routing failed to match, in which case
    the 404 handler takes over and the gate has nothing to decide.
    """
    rule = getattr(request, "url_rule", None)
    return getattr(rule, "rule", None) if rule is not None else None


def check_control_plane_request() -> Optional[Response]:
    """Enforce authentication for the current request if it is in scope.

    Returns None to continue the request, or a Response to short-circuit it.

    Scoping is by explicit rule exemption (ANONYMOUS_RULES) rather than by
    blueprint, so the answer to "is this route anonymous?" is a reviewable list
    instead of a side effect of where someone registered a view.
    """
    if not config.auth_enabled():
        return None

    rule = current_rule()
    if rule is None or rule in ANONYMOUS_RULES:
        return None

    identity = resolve_identity()
    if identity is None:
        return _reject_anonymous()

    blueprint = request.blueprint
    required = ROLE_ADMIN if blueprint in ADMIN_BLUEPRINTS else ROLE_VIEWER
    if not role_satisfies(identity.role, required):
        return _deny(403, f"This endpoint requires the '{required}' role.")

    # Stash for Phase B/C view functions; harmless while inert.
    from flask import g

    g.current_identity = identity
    return None


def require_auth(role: str = ROLE_VIEWER) -> Callable:
    """Decorator form of the gate, for per-route roles added in Phase B.

    Applied with enforcement off it is a pure pass-through - `wraps` preserves
    the endpoint name, so `url_for()` and the blueprint's bare-endpoint aliasing
    in `create_app` keep working.
    """

    def decorator(fn: Callable) -> Callable:
        @wraps(fn)
        def wrapper(*args, **kwargs):
            if not config.auth_enabled():
                return fn(*args, **kwargs)
            identity = resolve_identity()
            if identity is None:
                return _reject_anonymous()
            if not role_satisfies(identity.role, role):
                return _deny(403, f"This endpoint requires the '{role}' role.")
            from flask import g

            g.current_identity = identity
            return fn(*args, **kwargs)

        wrapper.__auth_role__ = role
        return wrapper

    return decorator


def warn_if_media_plane_anonymous() -> None:
    """Log the Phase E gap loudly when enforcement is on.

    Until signed URLs exist, `/media` and `/hls` are reachable without a
    credential. That is a known, deliberate gap in Phase A - it exists so Cast
    and DLNA keep working - but it must never be silent.
    """
    if not config.auth_enabled():
        return
    log.warning(
        "AUTH: the media plane (/media, /hls) is still anonymous. Cast and DLNA "
        "receivers cannot authenticate (cast_service.build_media_url hands them "
        "LAN URLs they fetch themselves), so signed URLs are Phase E. Until then "
        "anyone who can reach this host can stream any file."
    )


def startup_auth_diagnostics() -> None:
    """Report configuration problems at startup rather than at first request."""
    if not config.auth_enabled():
        log.info("AUTH: enforcement is OFF (MEDIA_SERVER_AUTH unset). Behaviour is unchanged.")
        return

    if config.secret_key() is None:
        log.error(
            "AUTH: enforcement is ON but MEDIA_SERVER_SECRET_KEY is unset. "
            "Refusing to sign anything. Set it in the NSSM service environment."
        )

    if not config.auth_allowlist():
        log.error(
            "AUTH: enforcement is ON but MEDIA_SERVER_AUTH_ALLOWLIST is empty, so "
            "nobody may sign in. The server is reachable from the internet - an "
            "empty allowlist is the safe state, but it is almost certainly not "
            "what you intended."
        )

    warn_if_media_plane_anonymous()