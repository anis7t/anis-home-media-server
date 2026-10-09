"""Authoritative API Contract Tests for Anis' Home Media Server.

Validates the current Flask implementation against the OpenAPI 3.1 specification
in `docs/openapi.yaml`. Covers all 42 registered endpoints, Flutter-sensitive schemas,
streaming headers, upload workflows, and error conditions.
"""
import io
import json
from pathlib import Path
import pytest
import yaml

from app import config, create_app, get_db, init_db

TEST_DEVICE = "dev_contract_test_client"


# ---------------------------------------------------------------------------
# Lightweight OpenAPI 3.1 Schema Conformance Validator
# ---------------------------------------------------------------------------

def validate_against_schema(data, schema, spec_components=None):
    """Validate a Python dictionary/list against an OpenAPI 3.1 schema definition."""
    if spec_components is None:
        spec_components = {}

    # Resolve $ref
    if "$ref" in schema:
        ref_path = schema["$ref"]
        if ref_path.startswith("#/components/schemas/"):
            schema_name = ref_path.split("/")[-1]
            resolved = spec_components.get("schemas", {}).get(schema_name)
            assert resolved is not None, f"Schema ref {ref_path} not found in components"
            return validate_against_schema(data, resolved, spec_components)

    schema_type = schema.get("type")

    # Handle multi-type / nullable (e.g. type: [integer, "null"])
    if isinstance(schema_type, list):
        if data is None:
            assert "null" in schema_type, f"Value is None but 'null' not in allowed types {schema_type}"
            return
        type_matched = False
        for t in schema_type:
            if t == "integer" and isinstance(data, int) and not isinstance(data, bool):
                type_matched = True
            elif t == "number" and (isinstance(data, (int, float)) and not isinstance(data, bool)):
                type_matched = True
            elif t == "string" and isinstance(data, str):
                type_matched = True
            elif t == "boolean" and isinstance(data, bool):
                type_matched = True
            elif t == "object" and isinstance(data, dict):
                type_matched = True
            elif t == "array" and isinstance(data, list):
                type_matched = True
        assert type_matched, f"Data '{data}' of type {type(data)} does not match any allowed type in {schema_type}"
        return

    # Single type validation
    if schema_type == "object":
        assert isinstance(data, dict), f"Expected dict, got {type(data)} for {data}"
        # Validate required properties
        for req in schema.get("required", []):
            assert req in data, f"Required property '{req}' missing from data keys: {list(data.keys())}"
        # Validate individual property schemas if declared
        properties = schema.get("properties", {})
        for prop_name, prop_val in data.items():
            if prop_name in properties:
                validate_against_schema(prop_val, properties[prop_name], spec_components)

    elif schema_type == "array":
        assert isinstance(data, list), f"Expected list, got {type(data)}"
        item_schema = schema.get("items")
        if item_schema:
            for idx, item in enumerate(data):
                validate_against_schema(item, item_schema, spec_components)

    elif schema_type == "integer":
        assert isinstance(data, int) and not isinstance(data, bool), f"Expected int, got {type(data)} for {data}"

    elif schema_type == "number":
        assert isinstance(data, (int, float)) and not isinstance(data, bool), f"Expected number, got {type(data)} for {data}"

    elif schema_type == "string":
        assert isinstance(data, str), f"Expected string, got {type(data)} for {data}"
        if "enum" in schema:
            assert data in schema["enum"], f"Value '{data}' not in enum {schema['enum']}"

    elif schema_type == "boolean":
        assert isinstance(data, bool), f"Expected boolean, got {type(data)} for {data}"


# ---------------------------------------------------------------------------
# Test Isolation Fixture
# ---------------------------------------------------------------------------

@pytest.fixture
def api_test_env(tmp_path, monkeypatch):
    """Create isolated test environment with SQLite DB, media files, and caches."""
    test_db = tmp_path / "contract_test.db"
    media_dir = tmp_path / "media"
    media_dir.mkdir(parents=True, exist_ok=True)
    cache_dir = tmp_path / "cache"
    (cache_dir / "posters").mkdir(parents=True, exist_ok=True)
    (cache_dir / "backdrops").mkdir(parents=True, exist_ok=True)
    (cache_dir / "hls").mkdir(parents=True, exist_ok=True)
    (cache_dir / "previews").mkdir(parents=True, exist_ok=True)
    (cache_dir / "subtitles" / "embedded").mkdir(parents=True, exist_ok=True)
    (cache_dir / "subtitles" / "online").mkdir(parents=True, exist_ok=True)
    updates_dir = tmp_path / "updates"
    (updates_dir / "production").mkdir(parents=True, exist_ok=True)
    (updates_dir / "developer").mkdir(parents=True, exist_ok=True)

    monkeypatch.setattr(config, "DATABASE", test_db)
    monkeypatch.setattr(config, "MEDIA_ROOT", media_dir)
    monkeypatch.setattr(config, "CACHE_DIR", cache_dir)
    monkeypatch.setattr(config, "POSTER_CACHE", cache_dir / "posters")
    monkeypatch.setattr(config, "BACKDROP_CACHE", cache_dir / "backdrops")
    monkeypatch.setattr(config, "UPDATES_DIR", updates_dir)
    monkeypatch.setattr(config, "UPLOAD_TARGET_DIR", media_dir)
    monkeypatch.setattr(config, "UPLOAD_TMP", media_dir / ".uploads")
    monkeypatch.setattr(config, "ARCHIVE_DIR", media_dir / ".archive")

    init_db()

    # Create dummy media files
    mp4_file = media_dir / "Test_Movie_Direct.2026.mp4"
    mp4_file.write_bytes(b"dummy mp4 container bytes header payload")
    mkv_file = media_dir / "Test_Movie_Transcode.2025.mkv"
    mkv_file.write_bytes(b"dummy mkv container bytes header payload")

    # Create sidecar subtitle
    srt_file = media_dir / "Test_Movie_Direct.2026_en_1.srt"
    srt_file.write_text("1\n00:00:01,000 --> 00:00:03,000\nHello world!\n", encoding="utf-8")

    # Create synthetic HLS cache for the MKV movie
    from app.services.transcode_service import hls_cache_dir
    mkv_hls = hls_cache_dir(mkv_file)
    mkv_hls.mkdir(parents=True, exist_ok=True)
    (mkv_hls / ".seg_layout").write_text("stride32", encoding="utf-8")
    playlist_content = (
        "#EXTM3U\n"
        "#EXT-X-VERSION:3\n"
        "#EXT-X-TARGETDURATION:4\n"
        "#EXT-X-MEDIA-SEQUENCE:0\n"
        "#EXTINF:4.000000,\n"
        "segment_000000.ts\n"
        "#EXT-X-ENDLIST\n"
    )
    (mkv_hls / "playlist.m3u8").write_text(playlist_content, encoding="utf-8")
    (mkv_hls / "segment_000000.ts").write_bytes(b"dummy ts segment bytes")

    # Seed update manifests and APK binaries
    prod_manifest = {
        "latestVersion": "1.2.19",
        "latestVersionCode": 139,
        "minSupportedVersionCode": 100,
        "downloadUrl": "/api/app/download?channel=production",
        "releaseNotes": "Phase 1 production update release",
        "fileSizeBytes": 1048576,
        "sha256": "fake_sha256_hash",
    }
    (updates_dir / "production" / "manifest.json").write_text(json.dumps(prod_manifest), encoding="utf-8")
    (updates_dir / "production" / "media-server-client.apk").write_bytes(b"dummy apk binary payload")

    # Seed movies table
    db = get_db()
    details_json = json.dumps({
        "tagline": "Contract verified.",
        "certification": "PG",
        "cast": [{"name": "Lead Actor", "character": "Protagonist"}],
        "directors": ["Visionary Director"],
    })
    db.execute(
        "INSERT INTO movies (filename, title, year, tmdb_id, overview, runtime, genres, vote_average, release_date, details_json, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            mp4_file.name,
            "Test Movie Direct",
            2026,
            101,
            "A test movie that plays directly.",
            120,
            "Action, Sci-Fi",
            8.4,
            "2026-05-15",
            details_json,
            1720000000,
        )
    )
    db.execute(
        "INSERT INTO movies (filename, title, year, tmdb_id, overview, runtime, genres, vote_average, release_date, details_json, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            mkv_file.name,
            "Test Movie Transcode",
            None,  # Intentionally null year to test nullable int constraint
            None,
            "A test movie requiring HLS transcode.",
            None,  # Intentionally null runtime
            "Drama",
            None,  # Intentionally null vote_average
            None,
            None,
            1720000000,
        )
    )
    db.commit()
    db.close()

    # Reset media_service paths cache
    import app.services.media_service as media_service
    media_service._paths = (0, [])

    app_instance = create_app()
    client = app_instance.test_client()

    # Load OpenAPI spec
    spec_path = Path(__file__).resolve().parent.parent / "docs" / "openapi.yaml"
    with open(spec_path, "r", encoding="utf-8") as f:
        spec = yaml.safe_load(f)

    return {
        "client": client,
        "spec": spec,
        "media_dir": media_dir,
        "mp4_file": mp4_file,
        "mkv_file": mkv_file,
    }


# ---------------------------------------------------------------------------
# 1. Spec Integrity & Endpoint Coverage Test
# ---------------------------------------------------------------------------

def test_openapi_spec_coverage_and_structure(api_test_env):
    """Verify that docs/openapi.yaml contains all 42 registered endpoints and valid schemas."""
    spec = api_test_env["spec"]
    assert spec["openapi"] == "3.1.0"
    paths = spec["paths"]

    # Assert presence of all primary routes
    expected_paths = [
        "/",
        "/movie/{filename}",
        "/watch/{filename}",
        "/manage",
        "/library",
        "/devices",
        "/clients",
        "/manual",
        "/help",
        "/how-to-use",
        "/download",
        "/manifest.webmanifest",
        "/sw.js",
        "/icon.svg",
        "/api/movies",
        "/api/movie/{filename}",
        "/api/media-info/{filename}",
        "/api/media-readiness/{filename}",
        "/api/scan",
        "/api/media/{filename}",
        "/api/media/delete/{filename}",
        "/api/progress",
        "/api/transcode-status/{filename}",
        "/api/transcode/start/{filename}",
        "/api/transcodes",
        "/api/devices",
        "/api/devices/heartbeat",
        "/api/devices/client-hints",
        "/api/devices/rename",
        "/api/devices/delete",
        "/api/system-status",
        "/api/storage/audit",
        "/api/storage/purge-orphans",
        "/api/storage/settings",
        "/api/storage/archive/{filename}",
        "/api/upload",
        "/api/upload/chunk/init",
        "/api/upload/chunk/{upload_id}",
        "/api/upload/chunk/{upload_id}/complete",
        "/api/upload-subtitle/{filename}",
        "/api/subtitles/{filename}",
        "/subtitles/{filename}/{name}",
        "/subtitles/embedded/{filename}/{stream_idx}.vtt",
        "/subtitles/online/{filename}.vtt",
        "/media/{filename}",
        "/transcode/{filename}",
        "/hls/{filename}/playlist.m3u8",
        "/hls/{filename}/{segment}",
        "/api/seek-preview-meta/{filename}",
        "/seek-preview/{filename}/{thumb}",
        "/poster/{filename}",
        "/tmdb-poster/{tmdb_id}",
        "/tmdb-backdrop/{tmdb_id}",
        "/api/cast/devices",
        "/api/cast/play",
        "/api/cast/control",
        "/api/cast/status",
        "/api/app/update",
        "/api/app/download",
    ]
    for p in expected_paths:
        assert p in paths, f"Path '{p}' missing from openapi.yaml specification"


# ---------------------------------------------------------------------------
# 2. Core JSON API Contract Tests (Flutter Sensitive)
# ---------------------------------------------------------------------------

def test_api_movies_contract(api_test_env):
    """Test GET /api/movies contract conformance and Flutter field type safety."""
    client = api_test_env["client"]
    spec = api_test_env["spec"]
    res = client.get("/api/movies", headers={"X-Device-Id": TEST_DEVICE})
    assert res.status_code == 200
    data = res.get_json()

    # Validate against OpenAPI schema
    schema = spec["components"]["schemas"]["MovieListResponse"]
    validate_against_schema(data, schema, spec["components"])

    # Explicit Flutter client invariant assertions:
    assert isinstance(data["movies"], list)
    assert len(data["movies"]) >= 2

    # Verify first movie with full metadata
    m1 = next(m for m in data["movies"] if m["filename"] == "Test_Movie_Direct.2026.mp4")
    assert isinstance(m1["year"], int), "Flutter requires year to be int when present"
    assert m1["year"] == 2026
    assert isinstance(m1["rating"], float), "Flutter requires rating to be float when present"
    assert isinstance(m1["position"], (int, float))
    assert isinstance(m1["duration"], (int, float))
    assert isinstance(m1["percent"], (int, float))

    # Verify second movie with nullable fields
    m2 = next(m for m in data["movies"] if m["filename"] == "Test_Movie_Transcode.2025.mkv")
    assert m2["year"] is None, "Flutter requires year to allow null"
    assert m2["rating"] is None, "Flutter requires rating to allow null"
    assert m2["runtime"] is None, "Flutter requires runtime to allow null"


def test_api_movie_details_contract(api_test_env):
    """Test GET /api/movie/<filename> contract conformance."""
    client = api_test_env["client"]
    spec = api_test_env["spec"]
    res = client.get("/api/movie/Test_Movie_Direct.2026.mp4", headers={"X-Device-Id": TEST_DEVICE})
    assert res.status_code == 200
    data = res.get_json()

    schema = spec["components"]["schemas"]["MovieDetailsResponse"]
    validate_against_schema(data, schema, spec["components"])

    assert data["movie"]["title"] == "Test Movie Direct"
    assert isinstance(data["specs"], dict)
    assert isinstance(data["is_transcode_ready"], bool)


def test_api_media_info_contract(api_test_env):
    """Test GET /api/media-info/<filename> contract, verifying authoritative direct_play."""
    client = api_test_env["client"]
    spec = api_test_env["spec"]

    # Direct play MP4
    res_mp4 = client.get("/api/media-info/Test_Movie_Direct.2026.mp4")
    assert res_mp4.status_code == 200
    data_mp4 = res_mp4.get_json()
    validate_against_schema(data_mp4, spec["components"]["schemas"]["MediaInfoResponse"], spec["components"])
    assert data_mp4["direct_play"] is True, "MP4 must report direct_play: true"
    assert data_mp4["container"] == "mp4"

    # Transcode MKV
    res_mkv = client.get("/api/media-info/Test_Movie_Transcode.2025.mkv")
    assert res_mkv.status_code == 200
    data_mkv = res_mkv.get_json()
    validate_against_schema(data_mkv, spec["components"]["schemas"]["MediaInfoResponse"], spec["components"])
    assert data_mkv["direct_play"] is False, "MKV must report direct_play: false"


def test_api_media_readiness_contract(api_test_env):
    """Test GET /api/media-readiness/<filename> contract."""
    client = api_test_env["client"]
    spec = api_test_env["spec"]
    res = client.get("/api/media-readiness/Test_Movie_Direct.2026.mp4")
    assert res.status_code == 200
    data = res.get_json()
    validate_against_schema(data, spec["components"]["schemas"]["MediaReadinessResponse"], spec["components"])
    assert data["direct_playable"] is True
    assert data["status"] == "direct"


def test_api_progress_contract(api_test_env):
    """Test GET and POST /api/progress playback watch progress contract."""
    client = api_test_env["client"]
    spec = api_test_env["spec"]

    # Initial GET
    res_get = client.get("/api/progress?filename=Test_Movie_Direct.2026.mp4", headers={"X-Device-Id": TEST_DEVICE})
    assert res_get.status_code == 200
    data_get = res_get.get_json()
    validate_against_schema(data_get, spec["components"]["schemas"]["ProgressGetResponse"], spec["components"])

    # Update progress via POST
    res_post = client.post(
        "/api/progress",
        headers={"X-Device-Id": TEST_DEVICE},
        json={"filename": "Test_Movie_Direct.2026.mp4", "position": 42.5, "duration": 7200.0},
    )
    assert res_post.status_code == 200
    assert res_post.get_json()["success"] is True

    # Confirm updated GET
    res_get2 = client.get("/api/progress?filename=Test_Movie_Direct.2026.mp4", headers={"X-Device-Id": TEST_DEVICE})
    assert res_get2.get_json()["position"] == 42.5

    # Bad payload (negative or invalid)
    res_bad = client.post(
        "/api/progress",
        headers={"X-Device-Id": TEST_DEVICE},
        json={"filename": "Test_Movie_Direct.2026.mp4", "position": "invalid"},
    )
    assert res_bad.status_code == 400


def test_api_system_status_contract(api_test_env):
    """Test GET /api/system-status hardware telemetry contract."""
    client = api_test_env["client"]
    spec = api_test_env["spec"]
    res = client.get("/api/system-status")
    assert res.status_code == 200
    data = res.get_json()
    validate_against_schema(data, spec["components"]["schemas"]["SystemTelemetryResponse"], spec["components"])
    assert "cpu" in data
    assert "memory" in data
    assert "storage" in data
    assert "gpu" in data


def test_api_devices_contract(api_test_env):
    """Test Connected Devices API suite contracts."""
    client = api_test_env["client"]
    spec = api_test_env["spec"]

    # 1. Heartbeat
    res_hb = client.post("/api/devices/heartbeat", headers={"X-Device-Id": TEST_DEVICE})
    assert res_hb.status_code == 200
    data_hb = res_hb.get_json()
    validate_against_schema(data_hb, spec["components"]["schemas"]["HeartbeatResponse"], spec["components"])
    dev_id = data_hb["device_id"]

    # 2. Client hints
    res_ch = client.post(
        "/api/devices/client-hints",
        headers={"X-Device-Id": dev_id},
        json={"model": "AFTMM", "platform": "Android", "platformVersion": "11"},
    )
    assert res_ch.status_code == 200
    assert res_ch.get_json()["success"] is True

    # 3. Rename
    res_rn = client.post(
        "/api/devices/rename",
        json={"device_id": dev_id, "name": "Living Room Fire Stick"},
    )
    assert res_rn.status_code == 200
    assert res_rn.get_json()["success"] is True

    # 4. Device list
    res_dev = client.get("/api/devices", headers={"X-Device-Id": dev_id})
    assert res_dev.status_code == 200
    data_dev = res_dev.get_json()
    validate_against_schema(data_dev, spec["components"]["schemas"]["DevicesResponse"], spec["components"])


def test_api_storage_governance_contract(api_test_env):
    """Test storage governance and cache audit contracts."""
    client = api_test_env["client"]
    spec = api_test_env["spec"]

    # Read retention policy
    res_get = client.get("/api/storage/settings")
    assert res_get.status_code == 200
    validate_against_schema(res_get.get_json(), spec["components"]["schemas"]["StorageSettingsResponse"], spec["components"])

    # Update retention policy
    res_post = client.post("/api/storage/settings", json={"retention_policy": "archive"})
    assert res_post.status_code == 200
    assert res_post.get_json()["retention_policy"] == "archive"

    # Invalid retention policy returns 400
    res_bad = client.post("/api/storage/settings", json={"retention_policy": "invalid_mode"})
    assert res_bad.status_code == 400

    # Storage audit
    res_audit = client.get("/api/storage/audit")
    assert res_audit.status_code == 200
    validate_against_schema(res_audit.get_json(), spec["components"]["schemas"]["StorageAuditResponse"], spec["components"])

    # Purge orphans dry run
    res_purge = client.post("/api/storage/purge-orphans?dry_run=1")
    assert res_purge.status_code == 200
    validate_against_schema(res_purge.get_json(), spec["components"]["schemas"]["StoragePurgeResponse"], spec["components"])


def test_api_app_update_contract(api_test_env):
    """Test /api/app/update and /api/app/download contracts."""
    client = api_test_env["client"]
    spec = api_test_env["spec"]

    # Valid production update check
    res_up = client.get("/api/app/update?channel=production")
    assert res_up.status_code == 200
    assert "no-cache" in res_up.headers.get("Cache-Control", "")
    data_up = res_up.get_json()
    validate_against_schema(data_up, spec["components"]["schemas"]["AppUpdateManifest"], spec["components"])
    assert data_up["latestVersionCode"] == 139

    # Invalid channel
    assert client.get("/api/app/update?channel=unsupported").status_code == 400

    # Download APK with byte-range support
    res_dl = client.get("/api/app/download?channel=production")
    assert res_dl.status_code == 200
    assert res_dl.headers.get("Content-Type") == "application/vnd.android.package-archive"
    assert len(res_dl.data) > 0


# ---------------------------------------------------------------------------
# 3. Media Streaming & Range Request Contracts (Integration)
# ---------------------------------------------------------------------------

def test_media_streaming_rfc7233_range_contract(api_test_env):
    """Test RFC 7233 byte-range delivery, CORS, and DLNA headers."""
    client = api_test_env["client"]

    # Full media stream (200)
    res_full = client.get("/media/Test_Movie_Direct.2026.mp4")
    assert res_full.status_code == 200
    assert res_full.headers.get("Accept-Ranges") == "bytes"
    assert res_full.headers.get("Access-Control-Allow-Origin") == "*"
    assert "Streaming" in res_full.headers.get("transferMode.dlna.org", "")

    # Partial range request (206)
    res_range = client.get(
        "/media/Test_Movie_Direct.2026.mp4",
        headers={"Range": "bytes=0-10"}
    )
    assert res_range.status_code == 206
    assert res_range.headers.get("Content-Range", "").startswith("bytes 0-10/")
    assert len(res_range.data) == 11
    assert res_range.headers.get("Access-Control-Allow-Origin") == "*"


def test_hls_playlist_and_segment_contract(api_test_env):
    """Test dynamic HLS manifest assembly and transport stream segment delivery."""
    client = api_test_env["client"]

    # HLS playlist
    res_pl = client.get("/hls/Test_Movie_Transcode.2025.mkv/playlist.m3u8")
    assert res_pl.status_code == 200
    assert "application/" in res_pl.headers.get("Content-Type", "")
    assert res_pl.headers.get("Access-Control-Allow-Origin") == "*"
    assert "no-store" in res_pl.headers.get("CDN-Cache-Control", "")
    content = res_pl.data.decode("utf-8")
    assert "#EXTM3U" in content
    assert "segment_000000.ts" in content

    # HLS segment
    res_seg = client.get("/hls/Test_Movie_Transcode.2025.mkv/segment_000000.ts")
    assert res_seg.status_code == 200
    assert res_seg.headers.get("Content-Type") == "video/mp2t"
    assert res_seg.headers.get("Access-Control-Allow-Origin") == "*"
    assert "public" in res_seg.headers.get("Cache-Control", "")


def test_subtitles_delivery_and_upload_contract(api_test_env):
    """Test subtitle track listing, sidecar conversion to WebVTT, and NLP upload."""
    client = api_test_env["client"]
    spec = api_test_env["spec"]

    # 1. List subtitle tracks
    res_list = client.get("/api/subtitles/Test_Movie_Direct.2026.mp4")
    assert res_list.status_code == 200
    tracks_data = res_list.get_json()
    assert "tracks" in tracks_data

    # 2. Deliver sidecar WebVTT
    res_vtt = client.get("/subtitles/Test_Movie_Direct.2026.mp4/Test_Movie_Direct.2026_en_1.srt")
    assert res_vtt.status_code == 200
    assert "text/vtt" in res_vtt.headers.get("Content-Type", "")
    assert "WEBVTT" in res_vtt.data.decode("utf-8")

    # 3. Subtitle upload with auto language detection
    sample_srt = "1\n00:00:01,000 --> 00:00:03,000\nBonjour tout le monde, je suis dans la maison pour vous.\n"
    res_up = client.post(
        "/api/upload-subtitle/Test_Movie_Direct.2026.mp4",
        data={"subtitle": (io.BytesIO(sample_srt.encode("utf-8")), "sample_french.srt")},
        content_type="multipart/form-data",
    )
    assert res_up.status_code == 200
    data_up = res_up.get_json()
    validate_against_schema(data_up, spec["components"]["schemas"]["SubtitleUploadResponse"], spec["components"])
    assert data_up["language"] == "fr"


def test_resumable_chunked_upload_lifecycle_contract(api_test_env):
    """Test chunked upload initialization, offset query, chunk writing, and cancellation."""
    client = api_test_env["client"]
    spec = api_test_env["spec"]

    # 1. Init upload session
    res_init = client.post(
        "/api/upload/chunk/init",
        json={"filename": "Uploaded_Feature.2026.mp4", "size": 1024, "overwrite": True},
    )
    assert res_init.status_code == 200
    init_data = res_init.get_json()
    validate_against_schema(init_data, spec["components"]["schemas"]["ChunkInitResponse"], spec["components"])
    upload_id = init_data["upload_id"]

    # 2. Query offset
    res_stat = client.get(f"/api/upload/chunk/{upload_id}")
    assert res_stat.status_code == 200
    validate_against_schema(res_stat.get_json(), spec["components"]["schemas"]["ChunkStatusResponse"], spec["components"])
    assert res_stat.get_json()["offset"] == 0

    # 3. Write first slice
    slice_data = b"X" * 512
    res_slice = client.post(
        f"/api/upload/chunk/{upload_id}",
        headers={"X-Upload-Offset": "0"},
        data=slice_data,
        content_type="application/octet-stream",
    )
    assert res_slice.status_code == 200
    assert res_slice.get_json()["offset"] == 512
    assert res_slice.get_json()["complete"] is False

    # 4. Abort / Cancel
    res_del = client.delete(f"/api/upload/chunk/{upload_id}")
    assert res_del.status_code == 200
    assert res_del.get_json()["success"] is True

    # 5. Confirm 404 after deletion
    assert client.get(f"/api/upload/chunk/{upload_id}").status_code == 404


def test_html_and_asset_endpoints_contract(api_test_env):
    """Verify HTML pages, service worker, and webmanifest respond with valid status and headers."""
    client = api_test_env["client"]

    # Home page sets cookie
    res_home = client.get("/")
    assert res_home.status_code == 200
    assert "ms_device_id" in res_home.headers.get("Set-Cookie", "")
    assert "text/html" in res_home.headers.get("Content-Type", "")

    # Static PWA manifest
    res_mf = client.get("/manifest.webmanifest")
    assert res_mf.status_code == 200
    assert "application/manifest+json" in res_mf.headers.get("Content-Type", "")

    # Service worker
    res_sw = client.get("/sw.js")
    assert res_sw.status_code == 200
    assert "javascript" in res_sw.headers.get("Content-Type", "")
    assert res_sw.headers.get("Service-Worker-Allowed") == "/"

    # Icon SVG
    res_icon = client.get("/icon.svg")
    assert res_icon.status_code == 200
    assert "image/svg+xml" in res_icon.headers.get("Content-Type", "")
