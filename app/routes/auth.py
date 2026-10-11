"""Google Sign-In routes - Phase B2.

The flow is the standard authorization-code flow with PKCE:

    GET  /auth/google          -> redirect to Google, stashing state/nonce/verifier
    GET  /auth/google/callback -> validate, exchange, verify, allowlist, session
    POST /auth/logout          -> clear our session
    GET  /api/auth/me          -> who am I (used by the React client)

`/auth/*` must stay reachable while everything else is gated, or there is no way
to sign in. They are added to ANONYMOUS_RULES deliberately and narrowly: only
the two Google entry points and the logout route, never `/auth/*` as a prefix.

The allowlist is enforced at the CALLBACK, after the token has been fully
verified, so an unlisted identity is rejected without a user row ever existing.
"""

from __future__ import annotations

import logging
import secrets
import time
from urllib.parse import urlencode

from flask import Blueprint, jsonify, redirect, request, session, url_for

from app import config
from app.services import auth_service, google_auth

log = logging.getLogger(__name__)

auth_bp = Blueprint("auth", __name__)

#: Temporary per-request secrets, held in the signed session until the callback.
_STATE_KEY = "_oauth_state"
_NONCE_KEY = "_oauth_nonce"
_VERIFIER_KEY = "_oauth_verifier"

#: How long an unfinished sign-in attempt stays valid.
_ATTEMPT_TTL_SECONDS = 600


def _redirect_uri() -> str:
    """The callback URI for this request.

    Derived from the incoming request by default so the same code works on the
    public hostname, the tailnet and localhost without configuration drifting.
    An explicit MEDIA_SERVER_GOOGLE_REDIRECT_URI overrides it when a proxy makes
    the external URL differ from what Flask sees.
    """
    configured = (config.google_redirect_uri() or "").strip()
    if configured:
        return configured
    return url_for("auth.google_callback", _external=True)


def _fail(message: str, status: int = 400):
    log.warning("AUTH: sign-in refused: %s", message)
    return jsonify({"error": message}), status


@auth_bp.route("/auth/google")
def google_start():
    """Begin sign-in: redirect to Google with state, nonce and PKCE."""
    problems = google_auth.configuration_problems()
    if problems:
        # A misconfigured deployment must say why, not redirect to a Google
        # error page the operator cannot interpret.
        log.error("AUTH: Google sign-in is not configured: %s", problems)
        return _fail("Sign-in is not configured on this server.", 503)

    verifier, challenge = google_auth.pkce_pair()
    state = secrets.token_urlsafe(32)
    nonce = secrets.token_urlsafe(32)

    session[_STATE_KEY] = state
    session[_NONCE_KEY] = nonce
    session[_VERIFIER_KEY] = verifier
    session[f"{_STATE_KEY}_at"] = int(time.time())

    return redirect(google_auth.build_authorize_url(
        _redirect_uri(), state, nonce, challenge
    ))


@auth_bp.route("/auth/google/callback")
def google_callback():
    """Complete sign-in. This is where trust is actually established."""
    problems = google_auth.configuration_problems()
    if problems:
        return _fail("Sign-in is not configured on this server.", 503)

    # --- 1. Did Google report an error? --------------------------------
    if request.args.get("error"):
        return _fail(f"Google returned an error: {request.args['error']}", 400)

    expected_state = session.pop(_STATE_KEY, None)
    # The nonce must be carried through to verification. Dropping it here would
    # silently skip that check, which is one of the three things binding the
    # callback to the request WE started.
    expected_nonce = session.pop(_NONCE_KEY, None)
    verifier = session.pop(_VERIFIER_KEY, None)
    started_at = session.pop(f"{_STATE_KEY}_at", None)

    # --- 2. state: binds the callback to OUR authorization request ------
    if not expected_state or not request.args.get("state"):
        return _fail("Sign-in state is missing. Start again from the sign-in link.", 400)
    if not secrets.compare_digest(str(expected_state), str(request.args["state"])):
        return _fail("Sign-in state mismatch. Start again from the sign-in link.", 400)
    if not started_at or (int(time.time()) - int(started_at)) > _ATTEMPT_TTL_SECONDS:
        return _fail("Sign-in attempt expired. Start again from the sign-in link.", 400)
    if not verifier:
        return _fail("Sign-in attempt is incomplete. Start again.", 400)

    code = request.args.get("code")
    if not code:
        return _fail("Google did not return an authorization code.", 400)

    # --- 3. Exchange and VERIFY. Nothing below trusts the payload. ------
    try:
        tokens = google_auth.exchange_code(code, _redirect_uri(), verifier)
    except Exception as exc:
        log.warning("AUTH: token exchange failed: %s", exc)
        return _fail("Could not complete sign-in with Google.", 502)

    try:
        claims = google_auth.verify_id_token(tokens["id_token"], expected_nonce)
    except Exception as exc:
        log.warning("AUTH: id_token verification failed: %s", exc)
        return _fail("Google sign-in could not be verified.", 401)

    # --- 4. THE ALLOWLIST. Checked only now. --------------------------
    email = claims.get("email")
    verified_email = claims.get("email_verified")
    if verified_email is False:
        return _fail("This Google account has no verified e-mail address.", 403)
    if not auth_service.is_allowed(email):
        log.warning("AUTH: rejected unlisted identity %s", email)
        # Deliberately not revealing whether the address is merely wrong.
        return _fail("This account is not permitted to use this server.", 403)

    # --- 5. Only now does a user row exist. ---------------------------
    user = google_auth.upsert_user(claims)
    google_auth.issue_session(user)

    destination = request.args.get("next") or "/"
    # Only same-site relative paths, so `next` cannot be used as an open
    # redirect to an attacker's site after a successful sign-in.
    if not destination.startswith("/") or destination.startswith("//"):
        destination = "/"
    return redirect(destination)


@auth_bp.route("/auth/logout", methods=["POST", "GET"])
def logout():
    google_auth.clear_session()
    return redirect("/")


@auth_bp.route("/api/auth/me")
def whoami():
    """Identity of the current caller, for the React client."""
    identity = auth_service.resolve_identity()
    if identity is None:
        return jsonify({"authenticated": False}), 200
    return jsonify({
        "authenticated": True,
        "email": identity.subject,
        "role": identity.role,
    })