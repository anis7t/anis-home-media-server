"""Server-side OAuth attempt storage — replaces session-cookie state."""
import time

from app.db import get_db

_TTL = 600


def store(state, nonce, verifier, redirect_uri, next_path):
    db = get_db()
    try:
        db.execute(
            "CREATE TABLE IF NOT EXISTS oauth_attempts ("
            "state TEXT PRIMARY KEY, nonce TEXT, verifier TEXT, redirect_uri TEXT,"
            "next_path TEXT, started_at INTEGER, used INTEGER DEFAULT 0)"
        )
        db.execute(
            "INSERT OR REPLACE INTO oauth_attempts "
            "(state, nonce, verifier, redirect_uri, next_path, started_at, used) "
            "VALUES (?, ?, ?, ?, ?, ?, 0)",
            (state, nonce, verifier, redirect_uri, next_path, int(time.time())),
        )
        db.commit()
    finally:
        db.close()


def get_and_clear(state):
    db = get_db()
    try:
        db.execute(
            "CREATE TABLE IF NOT EXISTS oauth_attempts ("
            "state TEXT PRIMARY KEY, nonce TEXT, verifier TEXT, redirect_uri TEXT,"
            "next_path TEXT, started_at INTEGER, used INTEGER DEFAULT 0)"
        )
        row = db.execute(
            "SELECT nonce, verifier, redirect_uri, next_path, started_at, used "
            "FROM oauth_attempts WHERE state = ?",
            (state,),
        ).fetchone()
        if row is None:
            return None
        # DELETE, not UPDATE used=1: a replayed state must read as missing so
        # the callback cannot be retried with it. UPDATE would leave the row
        # and a second call would hand the attacker the same secrets again.
        db.execute("DELETE FROM oauth_attempts WHERE state = ?", (state,))
        db.commit()
        return row
    finally:
        db.close()


def purge_older_than(ttl=_TTL):
    db = get_db()
    try:
        db.execute(
            "CREATE TABLE IF NOT EXISTS oauth_attempts ("
            "state TEXT PRIMARY KEY, nonce TEXT, verifier TEXT, redirect_uri TEXT,"
            "next_path TEXT, started_at INTEGER, used INTEGER DEFAULT 0)"
        )
        cutoff = int(time.time()) - ttl
        db.execute("DELETE FROM oauth_attempts WHERE started_at < ?", (cutoff,))
        db.commit()
    finally:
        db.close()