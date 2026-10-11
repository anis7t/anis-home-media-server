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
from app.services.auth_service import require_auth
from app.services import oauth_store

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

    # Server-side only — browsers drop session cookies across the redirect
    # from accounts.google.com (Safari ITP, Firefox ETP, Chrome 3P). The
    # session cookie no longer carries the OAuth binding; only our session
    # cookie (post-sign-in) remains.
    oauth_store.store(
        state, nonce, verifier,
        _redirect_uri(),
        request.args.get("next") or "/",
    )
    # Purge stale attempts on each attempt so the table stays bounded.
    oauth_store.purge_older_than()

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

    # --- 2. state: binds the callback to OUR authorization request ------
    # Read from the server-side store, not the session cookie. Browsers drop
    # the cookie across the accounts.google.com -> this-origin redirect (Safari
    # ITP, Firefox ETP, Chrome third-party), which is what produced
    # "Sign-in state is missing" on every affected browser.
    state_arg = request.args.get("state")
    if not state_arg:
        return _fail("Sign-in state is missing. Start again from the sign-in link.", 400)
    attempt = oauth_store.get_and_clear(state_arg)
    if attempt is None:
        return _fail("Sign-in state is missing. Start again from the sign-in link.", 400)
    nonce, verifier, redirect_uri, next_path, started_at, used = attempt
    if (int(time.time()) - int(started_at)) > _ATTEMPT_TTL_SECONDS:
        return _fail("Sign-in attempt expired. Start again from the sign-in link.", 400)
    if not verifier:
        return _fail("Sign-in attempt is incomplete. Start again.", 400)

    code = request.args.get("code")
    if not code:
        return _fail("Google did not return an authorization code.", 400)

    # --- 3. Exchange and VERIFY. Nothing below trusts the payload. ------
    try:
        tokens = google_auth.exchange_code(code, redirect_uri, verifier)
    except Exception as exc:
        log.warning("AUTH: token exchange failed: %s", exc)
        return _fail("Could not complete sign-in with Google.", 502)

    try:
        claims = google_auth.verify_id_token(tokens["id_token"], nonce)
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
    # Log successes as well as refusals. An auth system that records only the
    # failures cannot answer "who signed in, and when" - which is the first
    # question asked after a suspected compromise.
    log.info(
        "AUTH: sign-in succeeded sub=%s email=%s role=%s",
        claims.get("sub"), user["email"], user["role"],
    )

    # The DB stored the client's `next` at start; that avoids relying on the
    # URL query after Google rewrites it, and avoids open-redirect checks
    # against untrustworthy inputs.
    destination = next_path or "/"
    if not destination.startswith("/") or destination.startswith("//"):
        destination = "/"
    return redirect(destination)


@auth_bp.route("/auth/logout", methods=["POST", "GET"])
def logout():
    identity = auth_service.resolve_identity()
    google_auth.clear_session()
    if identity is not None:
        log.info("AUTH: sign-out subject=%s", identity.subject)
    return redirect("/")


@auth_bp.route("/api/auth/me")
def whoami():
    """Identity of the current caller, for the React client."""
    identity = auth_service.resolve_identity()
    if identity is None:
        return jsonify({"authenticated": False}), 200
    user = google_auth.get_user_by_sub(identity.subject)
    return jsonify({
        "authenticated": True,
        "email": identity.subject,
        "name": user.get("name"),
        "picture": user.get("picture_url"),
        "role": identity.role,
    })


# --------------------------------------------------------------------------- #
# API tokens (Phase C)
#
# Minting is admin-only and the plaintext is returned exactly once. Everything
# else here is metadata: the token itself is unrecoverable.
# --------------------------------------------------------------------------- #


@auth_bp.route("/api/auth/tokens", methods=["GET", "POST"])
@require_auth("admin")
def api_tokens():
    from app.services import token_service

    identity = auth_service.resolve_identity()
    # `require_auth` is a pass-through while enforcement is off, so this view
    # must refuse an absent identity itself rather than dereferencing None.
    if identity is None:
        return jsonify({"error": "Sign in as an administrator to manage tokens."}), 403

    if request.method == "GET":
        return jsonify({"tokens": token_service.list_tokens()})

    data = request.get_json(silent=True) or {}
    label = (data.get("label") or "").strip()
    if not label:
        # A bare token in a list of opaque ids is how you end up revoking the
        # wrong one.
        return jsonify({"error": "A label is required so the token can be identified later."}), 400
    validity = data.get("validity_days", token_service.DEFAULT_VALIDITY_DAYS)
    try:
        validity = int(validity) if validity is not None else None
        if validity is not None and validity <= 0:
            raise ValueError
    except (TypeError, ValueError):
        return jsonify({"error": "validity_days must be a positive integer or null."}), 400

    from app.db import get_db

    db = get_db()
    try:
        row = db.execute("SELECT id FROM users WHERE email=?", (identity.subject,)).fetchone()
    finally:
        db.close()
    if row is None:
        return jsonify({"error": "The signed-in account no longer exists."}), 403

    plaintext, record = token_service.create_token(row["id"], label, validity)
    pairing = token_service.pairing_payload(plaintext, request.host_url)

    log.info("AUTH: token minted for user_id=%s label=%r", row["id"], label)
    return jsonify({
        # Shown ONCE. Not recoverable afterwards.
        "token": plaintext,
        "pairing_url": pairing,
        "id": record["id"],
        "label": record["label"],
        "expires_at": record["expires_at"],
        "warning": "This token is displayed once and cannot be retrieved again.",
    }), 201


@auth_bp.route("/api/auth/tokens/<int:token_id>", methods=["DELETE"])
@require_auth("admin")
def revoke_api_token(token_id):
    from app.services import token_service

    if not token_service.revoke_token(token_id):
        return jsonify({"error": "No such active token."}), 404
    log.info("AUTH: token revoked id=%s", token_id)
    return jsonify({"revoked": token_id})


@auth_bp.route("/auth/pair")
def pair_device():
    """Exchange a pairing link's fragment token for a session cookie.

    The token arrives in the URL FRAGMENT, which browsers do not put in a
    request line - so it is never written to Cloudflare or Waitress access logs.
    A server-rendered page then moves it into the body for the POST below.
    """
    from flask import render_template_string

    return render_template_string(
        "<!doctype html><meta charset=utf-8>"
        "<title>Pair this device</title>"
        "<body style='font-family:system-ui;background:#090b10;color:#e8eaf0;padding:2rem'>"
        "<h1>Pairing this device</h1>"
        "<p id='msg'>Completing&hellip;</p>"
        "<form id='f' method='post' action='/auth/pair'></form>"
        "<script>"
        "const t=location.hash.slice(1);"
        "if(!t){document.getElementById('msg').textContent='No pairing token in the link.';}"
        "else{const f=document.getElementById('f');"
        "const i=document.createElement('input');i.name='token';i.value=decodeURIComponent(t);"
        "f.appendChild(i);f.submit();}"
        "</script></body>"
    )


@auth_bp.route("/auth/pair", methods=["POST"])
def pair_device_submit():
    """Exchange a pairing token for a session cookie on this browser.

    A device that opens the pairing link gets a session scoped to the USER the
    token belongs to. That is the step that makes "Anis Parvez on the TV" the
    same person as "Anis Parvez in the browser", which is what carries watch
    history and player settings across devices.
    """
    from app.services import token_service

    plaintext = (request.form.get("token") or "").strip()
    record = token_service.resolve_token(plaintext) if plaintext else None
    if record is None:
        # Do not distinguish "unknown", "revoked" and "expired" to the caller.
        return jsonify({"error": "That pairing token is not valid."}), 401

    google_auth.issue_session({
        "id": record["user_id"],
        "email": record["email"],
        "role": record["role"],
    })
    log.info("AUTH: device paired sub=%s email=%s", record["email"], record["email"])
    return redirect("/")