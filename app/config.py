"""Configuration and environment settings for the Media Server."""
import os
import signal
import threading
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

# Base directories
BASE_DIR = Path(os.environ.get("MEDIA_SERVER_BASE_DIR", Path(__file__).resolve().parent.parent)).resolve()
MEDIA_ROOT = Path(os.environ.get("MEDIA_SERVER_MEDIA_ROOT", "/home/iamroot/Media/Movies")).resolve()
DATABASE = Path(os.environ.get("MEDIA_SERVER_DATABASE", BASE_DIR / "media.db"))

# Cache directories
CACHE_DIR = BASE_DIR / "cache"
POSTER_CACHE = CACHE_DIR / "posters"
BACKDROP_CACHE = CACHE_DIR / "backdrops"
SUBTITLE_CACHE = CACHE_DIR / "subtitles"
SUBTITLE_EMBEDDED_CACHE = SUBTITLE_CACHE / "embedded"
SUBTITLE_ONLINE_CACHE = SUBTITLE_CACHE / "online"

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
ARCHIVE_DIR = Path(os.environ.get("MEDIA_SERVER_ARCHIVE_DIR", MEDIA_ROOT / ".archive")).resolve()
ALLOWED_RETENTION_POLICIES = {"keep", "archive", "purge_cache"}

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

