import hashlib
import os
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import app
from app.db import get_db
from app.services.media_service import purge_media, get_managed_media_items


class ManageAndPurgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.media_root = app.config.MEDIA_ROOT
        app.init_db()
        cls.client = app.app.test_client()

    def test_manage_and_library_routes_return_200(self):
        # Create a test media file so items list is non-empty
        vid = self.media_root / "ManageTest.2026.mp4"
        vid.write_bytes(b"0123456789")
        app._paths = (0, [])

        res_manage = self.client.get('/manage')
        self.assertEqual(res_manage.status_code, 200)
        self.assertIn(b"My Library", res_manage.data)
        self.assertIn(b"Media Storage", res_manage.data)
        self.assertIn(b"Delete & Purge", res_manage.data)

        res_library = self.client.get('/library')
        self.assertEqual(res_library.status_code, 200)
        self.assertIn(b"My Library", res_library.data)

        vid.unlink(missing_ok=True)
        app._paths = (0, [])

    def test_purge_media_comprehensive(self):
        # 1. Setup mock media file
        movie_name = "PurgeTarget.2026.mkv"
        movie_file = self.media_root / movie_name
        movie_file.write_bytes(b"mock movie contents for purge test")
        sidecar_sub = self.media_root / "PurgeTarget.2026.en.srt"
        sidecar_sub.write_text("1\n00:00:00,000 --> 00:00:01,000\nSubtitle\n")

        # 2. Database records
        db = get_db()
        db.execute(
            "INSERT OR REPLACE INTO movies (filename, title, year, tmdb_id, poster_path, backdrop_path, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (movie_name, "Purge Target", 2026, 888888, "tmdb:888888", "tmdb:888888", int(time.time()))
        )
        db.execute(
            "INSERT OR REPLACE INTO progress (filename, position, duration, updated_at) "
            "VALUES (?, ?, ?, CURRENT_TIMESTAMP)",
            (movie_name, 120.5, 3600.0)
        )
        db.commit()

        # 3. Setup mock caches
        cache_dir = app.config.CACHE_DIR
        posters_dir = app.config.POSTER_CACHE
        backdrops_dir = app.config.BACKDROP_CACHE
        embedded_sub_dir = app.config.SUBTITLE_EMBEDDED_CACHE
        online_sub_dir = app.config.SUBTITLE_ONLINE_CACHE
        hls_cache_dir = cache_dir / "hls"
        transcodes_dir = cache_dir / "transcodes"

        for d in (posters_dir, backdrops_dir, embedded_sub_dir, online_sub_dir, hls_cache_dir, transcodes_dir):
            d.mkdir(parents=True, exist_ok=True)

        cached_poster = posters_dir / "888888.jpg"
        cached_poster.write_bytes(b"mock poster image")
        cached_backdrop = backdrops_dir / "888888.jpg"
        cached_backdrop.write_bytes(b"mock backdrop image")

        # Subtitle hashes
        stamp = f"{movie_file}:{movie_file.stat().st_size}:{movie_file.stat().st_mtime_ns}".encode()
        file_hash = hashlib.sha256(stamp).hexdigest()[:16]
        cached_vtt = embedded_sub_dir / f"{file_hash}_0.vtt"
        cached_vtt.write_text("WEBVTT\n")

        stamp_online = f"{movie_file}:{movie_file.stat().st_size}".encode()
        online_hash = hashlib.sha256(stamp_online).hexdigest()[:16]
        cached_online_vtt = online_sub_dir / f"{online_hash}.vtt"
        cached_online_vtt.write_text("WEBVTT\n")

        # Mock HLS folder
        hls_target = hls_cache_dir / "test_hls_purge_dir"
        hls_target.mkdir(parents=True, exist_ok=True)
        (hls_target / "playlist.m3u8").write_text("#EXTM3U\n")
        (hls_target / "segment_000000.ts").write_bytes(b"chunk")

        class DummyProc:
            def __init__(self, hls_dir):
                self.hls_dir = hls_dir
                self.pid = 99999999
            def poll(self):
                return 0
            def terminate(self):
                pass

        app.config.HLS_PROCESSES[movie_name] = DummyProc(hls_target)

        # 4. Execute purge
        result = purge_media(movie_name)
        self.assertTrue(result['success'])
        self.assertTrue(result['file_deleted'])

        # 5. Verify all data wiped
        self.assertFalse(movie_file.exists(), "Source movie file must be deleted")
        self.assertFalse(sidecar_sub.exists(), "Sidecar subtitle file must be deleted")
        self.assertFalse(cached_poster.exists(), "TMDb poster cache must be deleted")
        self.assertFalse(cached_backdrop.exists(), "TMDb backdrop cache must be deleted")
        self.assertFalse(cached_vtt.exists(), "Embedded subtitle cache must be deleted")
        self.assertFalse(cached_online_vtt.exists(), "Online subtitle cache must be deleted")
        self.assertFalse(hls_target.exists(), "HLS stream cache directory must be deleted")

        # Verify DB records deleted
        db_check = get_db()
        m_row = db_check.execute("SELECT * FROM movies WHERE filename=?", (movie_name,)).fetchone()
        p_row = db_check.execute("SELECT * FROM progress WHERE filename=?", (movie_name,)).fetchone()
        db_check.close()
        self.assertIsNone(m_row, "Movies table row must be wiped")
        self.assertIsNone(p_row, "Progress table row must be wiped")

    def test_delete_media_api_endpoints(self):
        movie_name = "ApiPurge.2026.mp4"
        movie_file = self.media_root / movie_name
        movie_file.write_bytes(b"api test file")

        db = get_db()
        db.execute("INSERT OR REPLACE INTO movies (filename, title, year) VALUES (?, ?, ?)",
                   (movie_name, "API Purge", 2026))
        db.commit()
        db.close()

        # Test DELETE /api/media/<filename>
        res = self.client.delete(f'/api/media/{movie_name}')
        self.assertEqual(res.status_code, 200)
        data = res.get_json()
        self.assertTrue(data.get('success'))
        self.assertFalse(movie_file.exists())

        # Test fallback POST /api/media/delete/<filename>
        movie_file2 = self.media_root / "ApiPurge2.2026.mp4"
        movie_file2.write_bytes(b"api test file 2")
        res2 = self.client.post(f'/api/media/delete/{movie_file2.name}')
        self.assertEqual(res2.status_code, 200)
        self.assertTrue(res2.get_json().get('success'))
        self.assertFalse(movie_file2.exists())


if __name__ == '__main__':
    unittest.main()
