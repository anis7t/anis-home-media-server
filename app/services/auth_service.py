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

The media plane (`/media`, `/hls`) is NOT gated here. Cast and DLNA receivers
fetch those URLs themselves and cannot authenticate - see
`build_media_url()` in `app/services/cast_service.py:287`. Gating them is Phase E,
which introduces short-lived signed URLs. `warn_if_media_plane_anonymous()`
surfaces that gap loudly at startup instead of leaving it to be discovered.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from functools import wraps
from typing import Callable, Optional

from flask import Response, jsonify, request

from app import config

log = logging.getLogger(__name__)

#: Blueprints whose routes require a credential once enforcement is on.
#: Keyed on Flask's blueprint name (`request.blueprint`).
#:
#: `media` is deliberately absent - see the module docstring.
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

    Always None in Phase A: there is no credential provider to resolve. Phase B
    adds the session cookie, Phase C the bearer token.
    """
    return None


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


def check_control_plane_request() -> Optional[Response]:
    """Enforce authentication for the current request if it is in scope.

    Returns None to continue the request, or a Response to short-circuit it.

    Scoping is by blueprint name rather than URL prefix so that a new route is
    protected by default: anything registered on a protected blueprint is
    covered without anyone remembering to decorate it.
    """
    if not config.auth_enabled():
        return None

    blueprint = request.blueprint
    if blueprint not in PROTECTED_BLUEPRINTS:
        return None

    identity = resolve_identity()
    if identity is None:
        return _reject_anonymous()

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