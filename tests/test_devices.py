"""Unit and integration tests for client device tracking, network telemetry, and watch history."""
import json
import sqlite3
import pytest
from unittest.mock import patch, MagicMock

import app
from app import create_app, get_db
from app.services.device_service import (
    parse_user_agent,
    classify_connection,
    resolve_mac_address,
    lookup_geoip_and_isp,
    get_or_create_device_id,
    register_device_request,
    record_device_watch,
    get_all_devices,
    rename_device,
    delete_device,
    is_private_ip,
)


@pytest.fixture
def client(tmp_path, monkeypatch):
    """Create Flask test client with an isolated temporary database and media directory."""
    test_db = tmp_path / "test_media.db"
    media_dir = tmp_path / "media"
    media_dir.mkdir(parents=True, exist_ok=True)
    (media_dir / "sample.mp4").write_bytes(b"dummy video content 1234567890")
    (media_dir / "test.mp4").write_bytes(b"dummy video content 1234567890")

    monkeypatch.setattr(app.config, "DATABASE", test_db)
    monkeypatch.setattr(app.config, "MEDIA_ROOT", media_dir)
    app.init_db()

    flask_app = create_app()
    flask_app.config['TESTING'] = True
    with flask_app.test_client() as c:
        yield c


class TestUserAgentParsing:
    def test_iphone_safari(self):
        ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1"
        res = parse_user_agent(ua)
        assert res["device_type"] == "Mobile"
        assert "iOS" in res["device_os"]
        assert "Safari" in res["browser"]
        assert "iPhone" in res["device_name"]

    def test_android_phone_chrome(self):
        ua = "Mozilla/5.0 (Linux; Android 14; SM-S918B Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36"
        res = parse_user_agent(ua)
        assert res["device_type"] == "Mobile"
        assert "Android 14" in res["device_os"]
        assert "Chrome 128" in res["browser"]

    def test_ipad(self):
        ua = "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        res = parse_user_agent(ua)
        assert res["device_type"] == "Tablet"
        assert "iPadOS" in res["device_os"]
        assert "iPad" in res["device_name"]

    def test_windows_edge(self):
        ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 Edg/128.0.0.0"
        res = parse_user_agent(ua)
        assert res["device_type"] == "Desktop"
        assert "Windows 10/11" in res["device_os"]
        assert "Edge 128" in res["browser"]

    def test_linux_firefox(self):
        ua = "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"
        res = parse_user_agent(ua)
        assert res["device_type"] == "Desktop"
        assert res["device_os"] == "Linux"
        assert "Firefox 130" in res["browser"]

    def test_smart_tv_tizen(self):
        ua = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/4.0 Chrome/76.0.3809.146 TV Safari/537.36"
        res = parse_user_agent(ua)
        assert res["device_type"] == "Smart TV"
        assert "Tizen OS" in res["device_os"]
        assert "Samsung Smart TV" in res["device_name"]

    def test_lg_webos(self):
        ua = "Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.79 Safari/537.36 WebAppManager"
        res = parse_user_agent(ua)
        assert res["device_type"] == "Smart TV"
        assert "webOS" in res["device_os"]

    def test_empty_user_agent(self):
        res = parse_user_agent("")
        assert res["device_type"] == "Other"
        assert res["device_os"] == "Unknown OS"


class TestConnectionClassification:
    def test_localhost(self):
        req = MagicMock()
        req.headers = {}
        req.remote_addr = "127.0.0.1"
        res = classify_connection(req)
        assert res["connection_type"] == "Localhost (127.0.0.1)"
        assert res["client_ip"] == "127.0.0.1"
        assert res["public_ip"] is None
        assert not res["is_cloudflare"]

    def test_lan_connection(self):
        req = MagicMock()
        req.headers = {}
        req.remote_addr = "192.168.1.15"
        res = classify_connection(req)
        assert res["connection_type"] == "Local Network (LAN)"
        assert res["client_ip"] == "192.168.1.15"
        assert res["public_ip"] is None
        assert not res["is_cloudflare"]

    def test_cloudflare_header(self):
        req = MagicMock()
        req.headers = {
            "CF-Connecting-IP": "103.21.244.10",
            "CF-Ray": "87654321abcd",
            "Host": "random-subdomain.trycloudflare.com",
        }
        req.remote_addr = "127.0.0.1"
        res = classify_connection(req)
        assert res["connection_type"] == "Internet (Cloudflare Tunnel)"
        assert res["client_ip"] == "103.21.244.10"
        assert res["public_ip"] == "103.21.244.10"
        assert res["is_cloudflare"] is True

    def test_cloudflare_trycloudflare_host(self):
        req = MagicMock()
        req.headers = {
            "Host": "my-temporary-tunnel.trycloudflare.com",
            "X-Forwarded-For": "203.0.113.195",
        }
        req.remote_addr = "127.0.0.1"
        res = classify_connection(req)
        assert res["connection_type"] == "Internet (Cloudflare Tunnel)"
        assert res["client_ip"] == "203.0.113.195"
        assert res["is_cloudflare"] is True

    def test_direct_wan(self):
        req = MagicMock()
        req.headers = {"Host": "mediaserver.local"}
        req.remote_addr = "8.8.8.8"
        res = classify_connection(req)
        assert res["connection_type"] == "Internet (Direct)"
        assert res["client_ip"] == "8.8.8.8"
        assert res["public_ip"] == "8.8.8.8"


class TestMacResolution:
    def test_mac_localhost(self):
        assert resolve_mac_address("127.0.0.1", "Localhost (127.0.0.1)") == "Local Loopback (lo)"

    def test_mac_cloudflare(self):
        assert resolve_mac_address("103.21.244.10", "Internet (Cloudflare Tunnel)") == "WAN Proxy (Not L2 routable)"

    def test_mac_lan_lookup(self):
        mock_arp = "IP address       HW type     Flags       HW address            Mask     Device\n192.168.1.55     0x1         0x2         aa:bb:cc:dd:ee:ff     *        eth0"
        with patch("pathlib.Path.is_file", return_value=True), patch("pathlib.Path.read_text", return_value=mock_arp):
            mac = resolve_mac_address("192.168.1.55", "Local Network (LAN)")
            assert mac == "AA:BB:CC:DD:EE:FF"


class TestGeoIpAndIspLookup:
    def test_localhost_lookup(self):
        res = lookup_geoip_and_isp("127.0.0.1", "Localhost (127.0.0.1)")
        assert res["isp"] == "Local Loopback"
        assert res["city"] == "Localhost"

    def test_lan_lookup(self):
        res = lookup_geoip_and_isp("192.168.1.20", "Local Network (LAN)")
        assert res["isp"] == "Local Network (LAN)"
        assert res["city"] == "Home Network"

    def test_cached_public_ip(self, client):
        db = get_db()
        db.execute(
            "INSERT INTO ip_cache(ip, isp, org, city, country) VALUES(?, ?, ?, ?, ?)",
            ("1.1.1.1", "Cloudflare, Inc.", "Cloudflare", "Melbourne", "Australia")
        )
        db.commit()
        db.close()

        res = lookup_geoip_and_isp("1.1.1.1", "Internet (Cloudflare Tunnel)")
        assert res["isp"] == "Cloudflare, Inc."
        assert res["city"] == "Melbourne"
        assert res["country"] == "Australia"


class TestDeviceLifecycleAndRoutes:
    def test_page_stamps_device_cookie(self, client):
        res = client.get("/")
        assert res.status_code == 200
        # Cookie ms_device_id should be set
        cookies = res.headers.getlist("Set-Cookie")
        assert any("ms_device_id=dev_" in c for c in cookies)

    def test_devices_dashboard_render(self, client):
        res = client.get("/devices")
        assert res.status_code == 200
        html = res.get_data(as_text=True)
        assert "Connected Devices &amp; Telemetry" in html or "Connected Devices & Telemetry" in html
        assert "Total Devices" in html
        assert "Active Now" in html
        assert "Cloudflare Quick Tunnel" in html

    def test_clients_alias_render(self, client):
        res = client.get("/clients")
        assert res.status_code == 200
        assert "Total Devices" in res.get_data(as_text=True)

    def test_devices_json_api(self, client):
        res = client.get("/api/devices")
        assert res.status_code == 200
        data = res.get_json()
        assert "devices" in data
        assert "stats" in data
        assert "current_device_id" in data
        assert data["stats"]["total_devices"] >= 1

    def test_record_watch_and_dashboard_display(self, client):
        # 1. Send watch progress for a movie
        prog_res = client.post(
            "/api/progress",
            json={"filename": "sample.mp4", "position": 120.0, "duration": 600.0}
        )
        assert prog_res.status_code == 200

        # 2. Check that device watch history was recorded
        res = client.get("/api/devices")
        data = res.get_json()
        dev = data["devices"][0]
        assert dev["total_watched"] >= 1
        assert dev["recent_watch"]["filename"] == "sample.mp4"
        assert dev["recent_watch"]["percent"] == 20.0

        # 3. Verify on rendered HTML page
        html_res = client.get("/devices")
        html = html_res.get_data(as_text=True)
        assert "sample.mp4" in html or "Sample" in html
        assert "20.0%" in html or "20%" in html
        assert "Playback Activity &amp; Watch History" in html or "Playback Activity & Watch History" in html

    def test_rename_device_api(self, client):
        # Register a device first
        dev_res = client.get("/api/devices")
        dev_id = dev_res.get_json()["current_device_id"]

        # Rename device
        rename_res = client.post(
            "/api/devices/rename",
            json={"device_id": dev_id, "name": "Master Bedroom TV"}
        )
        assert rename_res.status_code == 200
        assert rename_res.get_json()["success"] is True

        # Check that new name reflects
        dev_res2 = client.get("/api/devices")
        updated_dev = next(d for d in dev_res2.get_json()["devices"] if d["device_id"] == dev_id)
        assert updated_dev["display_name"] == "Master Bedroom TV"
        assert updated_dev["custom_name"] == "Master Bedroom TV"

    def test_delete_device_api(self, client):
        # Register and watch
        client.post("/api/progress", json={"filename": "test.mp4", "position": 50, "duration": 100})
        dev_res = client.get("/api/devices")
        dev_id = dev_res.get_json()["current_device_id"]

        # Delete device
        del_res = client.post(
            "/api/devices/delete",
            json={"device_id": dev_id}
        )
        assert del_res.status_code == 200
        assert del_res.get_json()["success"] is True

        # Verify device no longer exists
        db = get_db()
        row = db.execute("SELECT * FROM devices WHERE device_id=?", (dev_id,)).fetchone()
        hist = db.execute("SELECT * FROM device_watch_history WHERE device_id=?", (dev_id,)).fetchall()
        db.close()
        assert row is None
        assert len(hist) == 0

    def test_nav_links_across_pages(self, client):
        # Verify /devices link is present on home, library/manage, details, and player
        home_html = client.get("/").get_data(as_text=True)
        assert 'href="/devices"' in home_html

        manage_html = client.get("/manage").get_data(as_text=True)
        assert 'href="/devices"' in manage_html
