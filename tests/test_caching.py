"""Tests for Cloudflare edge caching headers and development bypass triggers."""
import pytest
from app import create_app


@pytest.fixture
def client():
    app = create_app()
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


def test_static_asset_edge_caching(client):
    """Static assets should have 7-day Cloudflare edge caching headers."""
    resp = client.get("/static/css/main.css")
    assert resp.status_code == 200
    assert resp.headers.get("Cloudflare-CDN-Cache-Control") == "public, max-age=604800"
    assert resp.headers.get("CDN-Cache-Control") == "public, max-age=604800"
    assert resp.headers.get("X-Cache-Strategy") == "edge-immutable"
    assert "no-store" not in resp.headers.get("Cache-Control", "")


def test_dev_bypass_via_query_param(client):
    """Adding ?nocache=1 should force no-store and bypass headers."""
    resp = client.get("/static/css/main.css?nocache=1")
    assert resp.status_code == 200
    assert resp.headers.get("Cloudflare-CDN-Cache-Control") == "no-store"
    assert resp.headers.get("CDN-Cache-Control") == "no-store"
    assert resp.headers.get("X-Cache-Bypass") == "true"
    assert "no-store" in resp.headers.get("Cache-Control", "")


def test_dev_bypass_via_bypass_query_param(client):
    """Adding ?bypass=1 should force no-store and bypass headers."""
    resp = client.get("/static/css/main.css?bypass=1")
    assert resp.status_code == 200
    assert resp.headers.get("Cloudflare-CDN-Cache-Control") == "no-store"
    assert resp.headers.get("X-Cache-Bypass") == "true"


def test_dev_bypass_via_header(client):
    """Sending X-Bypass-Cache: 1 header should force no-store."""
    resp = client.get("/static/css/main.css", headers={"X-Bypass-Cache": "1"})
    assert resp.status_code == 200
    assert resp.headers.get("Cloudflare-CDN-Cache-Control") == "no-store"
    assert resp.headers.get("X-Cache-Bypass") == "true"


def test_dev_bypass_via_cache_control_no_cache(client):
    """Sending Cache-Control: no-cache header should force no-store."""
    resp = client.get("/static/css/main.css", headers={"Cache-Control": "no-cache"})
    assert resp.status_code == 200
    assert resp.headers.get("Cloudflare-CDN-Cache-Control") == "no-store"
    assert resp.headers.get("X-Cache-Bypass") == "true"


def test_dynamic_api_no_store(client):
    """Dynamic API endpoints should default to no-store on Cloudflare CDN."""
    resp = client.get("/api/system-status")
    assert resp.status_code == 200
    assert resp.headers.get("Cloudflare-CDN-Cache-Control") == "no-store"
    assert resp.headers.get("CDN-Cache-Control") == "no-store"
    assert resp.headers.get("X-Cache-Strategy") == "dynamic-origin"
