"""Configuration and environment settings for the Media Server."""
import os
import signal
import threading
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(os.environ.get("MEDIA_SERVER_BASE_DIR", Path(__file__).resolve().parent.parent)).resolve()
import sys
if "pytest" in sys.modules or os.environ.get("MEDIA_SERVER_MEDIA_ROOT"):
    load_dotenv(BASE_DIR / ".env", override=False)
else:
    load_dotenv(BASE_DIR / ".env", override=True)

# Base directories
MEDIA_ROOT = Path(os.environ.get("MEDIA_SERVER_MEDIA_ROOT", "D:/Flicks" if os.name == "nt" else BASE_DIR / "media")).resolve()
DATABASE = Path(os.environ.get("MEDIA_SERVER_DATABASE", BASE_DIR / "media.db"))
DATABASE_BACKEND = os.environ.get("MEDIA_SERVER_DATABASE_BACKEND", "sqlite").lower().strip()
DATABASE_URL = os.environ.get("MEDIA_SERVER_DATABASE_URL", "").strip() or None
ALLOWED_DATABASE_BACKENDS = frozenset({"sqlite", "postgres", "postgresql"})

# Cache directories
#
# MEDIA_SERVER_CACHE_DIR follows the same contract as MEDIA_SERVER_MEDIA_ROOT and
# MEDIA_SERVER_DATABASE above: unset means the default under BASE_DIR. It exists
# because CACHE_DIR was previously the one writable path with NO environment
# override, so any process that wanted a different cache tree had to monkeypatch
# `app.CACHE_DIR` or `config.CACHE_DIR` after import. That asymmetry is what let a
# misdirected cache path reach the destructive maintenance functions in
# app/services/transcode_service.py.
#
# A blank or whitespace-only value is treated as ABSENT, not as a path: Path("")
# resolves to the process working directory, which would silently install the
# working directory as the cache root (and, after the checks below, as an approved
# root for deletion). This mirrors the `.strip() or None` idiom already used for
# DATABASE_URL above.
#
# Relative values are resolved against the process working directory at import
# time (normal Path.resolve semantics); the default is already absolute because
# BASE_DIR is resolved, so an unset value leaves CACHE_DIR exactly as before.
_cache_dir_override = (os.environ.get("MEDIA_SERVER_CACHE_DIR") or "").strip()
CACHE_DIR = Path(_cache_dir_override).resolve() if _cache_dir_override else (BASE_DIR / "cache")
del _cache_dir_override
POSTER_CACHE = CACHE_DIR / "posters"
BACKDROP_CACHE = CACHE_DIR / "backdrops"
SUBTITLE_CACHE = CACHE_DIR / "subtitles"
SUBTITLE_EMBEDDED_CACHE = SUBTITLE_CACHE / "embedded"
SUBTITLE_ONLINE_CACHE = SUBTITLE_CACHE / "online"
UPDATES_DIR = Path(os.environ.get("MEDIA_SERVER_UPDATES_DIR", BASE_DIR / "updates")).resolve()

# --------------------------------------------------------------------------- #
# Cache-root safety boundary (Phase 3.8D)
#
# Every destructive cache deletion funnels through here. It lives in config
# rather than in transcode_service so that media_service, subtitles_service,
# preview_service and transcode_service all reach the SAME check without creating
# import cycles (each already imports `config`).
#
# WHAT THIS ESTABLISHES: internal consistency plus containment.
# WHAT IT DOES NOT ESTABLISH: that the configured root is the *intended* one.
# Agreement proves the two configuration sources describe the same tree; it is
# not proof that the tree is the right tree to delete from. The configured root
# remains an operational trust boundary.
# --------------------------------------------------------------------------- #


class CacheRootUnsafe(RuntimeError):
    """A destructive cache operation refused to run.

    Raised when the cache root cannot be established as the single configured
    root, so no deletion can be proven to stay inside it.
    """


def _cache_key(path):
    """Normalise *path* for comparison. Does not require it to exist."""
    return os.path.normcase(os.path.realpath(str(path)))


def approved_cache_root():
    """Return the one cache root that destructive operations may touch.

    Fail closed.

    ``config.CACHE_DIR`` is the declared root; ``app.CACHE_DIR`` is the legacy
    override that ``transcode_service.get_cache_dir()`` prefers. Both are checked
    and must agree, because a partial override would otherwise let a deletion aim
    at a different tree than the derived constants (``POSTER_CACHE``,
    ``SUBTITLE_*``) still describe.

    In production both names are the same object (``app/__init__.py`` re-exports
    ``CACHE_DIR``), so this never refuses a correctly configured server.
    """
    declared = getattr(sys.modules[__name__], 'CACHE_DIR', None)
    # Reject an empty/blank root deterministically. Path("") stringifies to ".",
    # which normalises to the process working directory - exactly the accidental
    # "the working directory is the cache" state this check exists to prevent.
    raw = "" if declared is None else str(declared).strip()
    if not raw or raw == '.':
        raise CacheRootUnsafe(
            f"cache root is unset or resolves to the working directory: {declared!r}"
        )
    try:
        declared_key = _cache_key(declared)
    except (TypeError, ValueError):
        raise CacheRootUnsafe(
            f"cache root is not a usable path: {declared!r}"
        ) from None

    app_module = sys.modules.get('app')
    override = getattr(app_module, 'CACHE_DIR', None) if app_module is not None else None
    if override is not None and _cache_key(override) != declared_key:
        raise CacheRootUnsafe(
            f"conflicting cache roots: config.CACHE_DIR={declared_key} vs "
            f"app.CACHE_DIR={_cache_key(override)}; refusing a destructive "
            "cache operation."
        )
    return Path(os.path.realpath(str(declared)))


def require_within_cache_root(target, action="cache operation"):
    """Refuse *target* unless it is the approved cache root or lives inside it.

    Applied to the directory or file actually about to be removed, not to the
    configuration value it was derived from. Raises before any mutation and never
    redirects the target.
    """
    root = approved_cache_root()
    try:
        resolved = _cache_key(target)
    except (TypeError, ValueError):
        raise CacheRootUnsafe(
            f"{action} target could not be resolved: {target!r}"
        ) from None
    root_key = _cache_key(root)
    if resolved != root_key and not resolved.startswith(root_key + os.sep):
        raise CacheRootUnsafe(
            f"{action} target {resolved} is outside the approved cache root "
            f"{root_key}; refusing."
        )
    return Path(os.path.realpath(str(target)))


# Supported file extensions
VIDEO_EXTENSIONS = {".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v"}
SUBTITLE_EXTENSIONS = {".srt", ".vtt"}
POSTER_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}

# Limits & Intervals
CACHE_MAX_BYTES = 10 * 1024 * 1024 * 1024  # 10 GB transcode cache limit
PRECACHE_INTERVAL = 30
SCAN_INTERVAL = 120
METADATA_REFRESH_INTERVAL = int(os.environ.get("MEDIA_SERVER_METADATA_REFRESH_INTERVAL", 4 * 3600))  # 4 hours in seconds

# Storage Retention Policies ('keep', 'archive', 'purge_cache')
DEFAULT_RETENTION_POLICY = os.environ.get("MEDIA_SERVER_RETENTION_POLICY", "keep").lower()


def _resolve_default_archive_dir():
    env_dir = os.environ.get("MEDIA_SERVER_ARCHIVE_DIR")
    if env_dir:
        return Path(env_dir).resolve()
    try:
        d_flicks = Path("D:/Flicks/.archive")
        if Path("D:/").exists():
            return d_flicks.resolve()
    except Exception:
        pass
    return (MEDIA_ROOT / ".archive").resolve()


ARCHIVE_DIR = _resolve_default_archive_dir()


def _resolve_default_deleted_dir():
    env_dir = os.environ.get("MEDIA_SERVER_DELETED_DIR")
    if env_dir:
        return Path(env_dir).resolve()
    try:
        d_flicks = Path("D:/Flicks/.deleted")
        if Path("D:/").exists():
            return d_flicks.resolve()
    except Exception:
        pass
    return (MEDIA_ROOT / ".deleted").resolve()


DELETED_DIR = _resolve_default_deleted_dir()

ALLOWED_RETENTION_POLICIES = {"keep", "archive", "purge_cache", "delete_source", "delete_raw", "delete_original"}


def _resolve_upload_dirs():
    import sys
    env_target = os.environ.get("MEDIA_SERVER_UPLOAD_TARGET_DIR")
    env_tmp = os.environ.get("MEDIA_SERVER_UPLOAD_TMP")
    if "pytest" in sys.modules and not env_target:
        return MEDIA_ROOT, MEDIA_ROOT / ".uploads"

    d_available = False
    try:
        d_available = Path("D:/").exists()
    except Exception:
        d_available = False

    target = Path(env_target).resolve() if env_target else (Path("D:/Flicks").resolve() if d_available else MEDIA_ROOT)
    tmp = Path(env_tmp).resolve() if env_tmp else (Path("D:/Flicks/.uploads").resolve() if d_available else (MEDIA_ROOT / ".uploads"))
    return target, tmp


UPLOAD_TARGET_DIR, UPLOAD_TMP = _resolve_upload_dirs()


def get_media_roots():
    """Return all active media root directories searched for media files."""
    import sys
    roots = [MEDIA_ROOT]
    if "pytest" in sys.modules and not os.environ.get("TEST_ENABLE_MULTI_ROOT"):
        if ARCHIVE_DIR != MEDIA_ROOT and ARCHIVE_DIR not in roots and ARCHIVE_DIR.exists():
            roots.append(ARCHIVE_DIR)
        return roots

    for candidate in (UPLOAD_TARGET_DIR, ARCHIVE_DIR):
        if candidate and candidate not in roots and candidate.exists():
            roots.append(candidate)
    return roots

# Concurrency & process registries
SHUTDOWN_EVENT = threading.Event()
SUBTITLE_LOCKS = {}
TRANSCODE_LOCKS = {}
HLS_PROCESSES = {}
ACTIVE_DIRECT_TRANSCODES = {}
SCANNER_LOCK = threading.Lock()

# Logging level
LOG_LEVEL = os.environ.get("MEDIA_SERVER_LOG_LEVEL", "INFO")


def _sig_handler(sig, frame):
    SHUTDOWN_EVENT.set()
    os._exit(0)


try:
    signal.signal(signal.SIGTERM, _sig_handler)
    signal.signal(signal.SIGINT, _sig_handler)
except (ValueError, AttributeError):
    pass


def is_vaapi_enabled():
    """Check if VAAPI hardware acceleration is enabled and device is accessible."""
    if os.environ.get("MEDIA_SERVER_ENABLE_VAAPI", "0").lower() in {"1", "true", "yes"}:
        dev = os.environ.get("MEDIA_SERVER_VAAPI_DEVICE", "/dev/dri/renderD128")
        return Path(dev).exists() and os.access(dev, os.R_OK | os.W_OK)
    return False

def is_amf_enabled():
    """Check whether AMD AMF hardware encoding is enabled by configuration."""
    return os.environ.get("MEDIA_SERVER_ENABLE_AMF", "0").lower() in {"1", "true", "yes"}

