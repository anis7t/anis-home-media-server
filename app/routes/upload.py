"""Resumable chunked media uploads for reverse-proxy-safe large files."""
import json
import logging
import os
import re
import secrets
import sys
import threading
import time
from pathlib import Path

from flask import jsonify, request

from app import config
from app.db import get_db
from app.routes.api import api_bp
from app.services.scanner_service import trigger_library_scan

logger = logging.getLogger(__name__)

CHUNK_SIZE = 8 * 1024 * 1024
MAX_UPLOAD_BYTES = 20 * 1024 * 1024 * 1024
UPLOAD_TMP = config.MEDIA_ROOT / ".uploads"
UPLOAD_ID_RE = re.compile(r"^[A-Za-z0-9_-]{20,64}$")


def _ensure_upload_dir():
    UPLOAD_TMP.mkdir(parents=True, exist_ok=True)


def _paths(upload_id):
    if not UPLOAD_ID_RE.fullmatch(upload_id):
        return None, None
    return UPLOAD_TMP / f"{upload_id}.part", UPLOAD_TMP / f"{upload_id}.json"


def _safe_filename(filename):
    raw_name = Path(filename or "").name
    clean_name = re.sub(r'[/\\:\x00]', '', raw_name).strip()
    if not clean_name or clean_name in {'.', '..'}:
        raise ValueError("Invalid filename provided.")
    suffix = Path(clean_name).suffix.lower()
    if suffix not in config.VIDEO_EXTENSIONS:
        allowed = ", ".join(sorted(config.VIDEO_EXTENSIONS))
        raise ValueError(f"Unsupported video format '{suffix}'. Allowed formats: {allowed}")
    return clean_name, suffix


def _is_anonymous_filename(filename):
    """Return True for numeric/generic device-generated filenames that cannot safely identify a movie."""
    stem = Path(filename).stem.strip(" -._'\"")
    if not stem:
        return True
    if re.fullmatch(r"\d+", stem):
        return True
    if re.fullmatch(r"[0-9a-fA-F-]{8,}", stem):
        return True
    generic_prefixes = (
        "vid_", "video_", "mov_", "movie_", "dsc_", "img_",
        "untitled", "unknown", "file", "upload", "stream", "part"
    )
    lower = stem.lower()
    return any(
        lower.startswith(prefix)
        and (len(lower) == len(prefix) or re.search(r"\d", lower))
        for prefix in generic_prefixes
    )


def _safe_target_name(clean_name):
    config.MEDIA_ROOT.mkdir(parents=True, exist_ok=True)
    target_path = (config.MEDIA_ROOT / clean_name).resolve()
    media_root = config.MEDIA_ROOT.resolve()
    if not str(target_path).startswith(str(media_root) + os.sep):
        raise ValueError("Illegal destination path.")
    if not target_path.exists():
        return target_path

    stem = Path(clean_name).stem
    suffix = Path(clean_name).suffix
    counter = 1
    while True:
        candidate = (config.MEDIA_ROOT / f"{stem} ({counter}){suffix}").resolve()
        if not candidate.exists():
            return candidate
        counter += 1


def _write_manifest(manifest_path, manifest):
    temp = manifest_path.with_suffix('.json.tmp')
    temp.write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")
    temp.replace(manifest_path)


def _read_manifest(manifest_path):
    try:
        return json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None


def _prepare_media(target_path):
    import scanner

    import app.services.media_service as media_service
    media_service._paths = (0, [])
    if 'app' in sys.modules and hasattr(sys.modules['app'], '_paths'):
        sys.modules['app']._paths = (0, [])

    scanned_details = None
    try:
        scanned_details = scanner.scan_single_file(target_path)
    except Exception as exc:
        logger.warning("Scan single file during upload error: %s", exc)

    rel_filename = target_path.relative_to(config.MEDIA_ROOT).as_posix()
    parsed_title, parsed_year = scanner.parse_filename(target_path)

    if not scanned_details:
        try:
            db = get_db()
            db.execute(
                "INSERT OR IGNORE INTO movies (filename, title, year, updated_at) VALUES (?, ?, ?, ?)",
                (rel_filename, parsed_title, parsed_year, int(time.time()))
            )
            db.commit()
            db.close()
        except Exception:
            pass

    trigger_library_scan()

    from app.services.transcode_service import needs_transcode, ensure_hls_transcode
    transcode_started = False
    if needs_transcode(target_path):
        try:
            ensure_hls_transcode(rel_filename)
            transcode_started = True
        except Exception:
            pass

    from app.services.subtitles_service import tracks
    try:
        threading.Thread(
            target=tracks,
            args=(target_path, scanned_details),
            name="sub-prefetch",
            daemon=True
        ).start()
    except Exception:
        pass

    display_title = (scanned_details.get("title") if scanned_details else None) or parsed_title
    raw_year = (
        scanned_details.get("release_date", "")[:4]
        if (scanned_details and scanned_details.get("release_date"))
        else None
    ) or parsed_year
    try:
        display_year = int(raw_year) if raw_year else None
    except (ValueError, TypeError):
        display_year = raw_year

    return {
        "success": True,
        "filename": rel_filename,
        "title": display_title,
        "year": display_year,
        "needs_transcode": transcode_started,
        "details_url": f"/movie/{rel_filename}",
    }


@api_bp.route('/api/upload/chunk/init', methods=['POST'])
def chunk_upload_init():
    data = request.get_json(silent=True) or {}
    try:
        clean_name, suffix = _safe_filename(data.get('filename', ''))
        total_size = int(data.get('size', 0))
    except (ValueError, TypeError) as exc:
        return jsonify(error=str(exc)), 400

    if total_size <= 0:
        return jsonify(error="Upload size must be greater than zero."), 400
    if total_size > MAX_UPLOAD_BYTES:
        return jsonify(error="Upload exceeds the 20 GiB server safety limit."), 413

    custom_title = str(data.get('title', '') or '').strip()
    if custom_title:
        safe_title = re.sub(r'[/\\:\x00*?"<>|]', ' ', custom_title).strip()
        safe_title = re.sub(r'\s+', ' ', safe_title)
        if safe_title:
            clean_name = f"{safe_title}{suffix}"
    elif _is_anonymous_filename(clean_name):
        return jsonify(
            error="This upload has an anonymous or numeric filename. Enter the movie title before uploading so the server does not guess the wrong movie."
        ), 400

    upload_id = secrets.token_urlsafe(24)
    _ensure_upload_dir()
    part_path, manifest_path = _paths(upload_id)
    part_path.touch(exist_ok=False)
    _write_manifest(manifest_path, {
        "filename": clean_name,
        "size": total_size,
        "created_at": int(time.time()),
    })

    return jsonify(
        success=True,
        upload_id=upload_id,
        filename=clean_name,
        size=total_size,
        offset=0,
        chunk_size=CHUNK_SIZE,
    )


@api_bp.route('/api/upload/chunk/<upload_id>', methods=['GET', 'POST', 'DELETE'])
def chunk_upload(upload_id):
    part_path, manifest_path = _paths(upload_id)
    if part_path is None:
        return jsonify(error="Invalid upload ID."), 400

    manifest = _read_manifest(manifest_path)
    if manifest is None or not part_path.exists():
        return jsonify(error="Upload session not found."), 404

    if request.method == 'GET':
        return jsonify(
            success=True,
            upload_id=upload_id,
            filename=manifest["filename"],
            size=manifest["size"],
            offset=part_path.stat().st_size,
            chunk_size=CHUNK_SIZE,
        )

    if request.method == 'DELETE':
        part_path.unlink(missing_ok=True)
        manifest_path.unlink(missing_ok=True)
        return jsonify(success=True)

    try:
        offset = int(request.headers.get('X-Upload-Offset', '0'))
        content_length = request.content_length
    except (TypeError, ValueError):
        return jsonify(error="Invalid upload offset or content length."), 400

    current_offset = part_path.stat().st_size
    total_size = int(manifest["size"])
    if offset != current_offset:
        return jsonify(
            error="Upload offset does not match server state.",
            current_offset=current_offset,
        ), 409
    if content_length is None or content_length <= 0:
        return jsonify(error="Chunk body is empty."), 400
    if content_length > CHUNK_SIZE:
        return jsonify(error=f"Chunk exceeds the {CHUNK_SIZE // (1024 * 1024)} MiB chunk limit."), 413
    if offset + content_length > total_size:
        return jsonify(error="Chunk exceeds declared upload size."), 400

    remaining = content_length
    try:
        with open(part_path, 'r+b') as out_f:
            out_f.seek(offset)
            while remaining:
                data = request.stream.read(min(1024 * 1024, remaining))
                if not data:
                    break
                out_f.write(data)
                remaining -= len(data)
            out_f.flush()
            os.fsync(out_f.fileno())
    except Exception as exc:
        return jsonify(error=f"Failed to write upload chunk: {exc}"), 500

    new_offset = part_path.stat().st_size
    if new_offset != offset + content_length:
        return jsonify(error="Incomplete chunk received.", current_offset=new_offset), 502

    return jsonify(
        success=True,
        upload_id=upload_id,
        offset=new_offset,
        size=total_size,
        complete=(new_offset == total_size),
    )


@api_bp.route('/api/upload/chunk/<upload_id>/complete', methods=['POST'])
def chunk_upload_complete(upload_id):
    part_path, manifest_path = _paths(upload_id)
    if part_path is None:
        return jsonify(error="Invalid upload ID."), 400

    manifest = _read_manifest(manifest_path)
    if manifest is None or not part_path.exists():
        return jsonify(error="Upload session not found."), 404

    expected_size = int(manifest["size"])
    actual_size = part_path.stat().st_size
    if actual_size != expected_size:
        return jsonify(error="Upload is incomplete.", current_offset=actual_size, size=expected_size), 409

    try:
        target_path = _safe_target_name(manifest["filename"])
        part_path.replace(target_path)
        result = _prepare_media(target_path)
    except Exception as exc:
        logger.exception("Failed to finalize chunked upload %s", upload_id)
        return jsonify(error=f"Failed to finalize uploaded media: {exc}"), 500
    finally:
        manifest_path.unlink(missing_ok=True)

    return jsonify(result)
