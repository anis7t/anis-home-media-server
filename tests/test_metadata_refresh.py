"""Unit and integration tests for TMDb metadata refresh, schema migrations, and worker loop."""
import json
import sqlite3
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import app
from app import config, create_app, get_db, init_db
from app.services.tmdb_service import (
    refresh_all_library_metadata,
    refresh_movie_metadata,
)
from app.services.scanner_service import (
    run_library_scan,
    trigger_library_scan,
)
from app.services.worker_service import (
    start_metadata_refresh_worker,
)


@pytest.fixture
def client(tmp_path, monkeypatch):
    """Create Flask test client with an isolated temporary database and media directory."""
    test_db = tmp_path / "test_metadata.db"
    media_dir = tmp_path / "movies"
    media_dir.mkdir(parents=True, exist_ok=True)
    poster_cache = tmp_path / "cache" / "posters"
    poster_cache.mkdir(parents=True, exist_ok=True)
    backdrop_cache = tmp_path / "cache" / "backdrops"
    backdrop_cache.mkdir(parents=True, exist_ok=True)

    monkeypatch.setattr(config, "DATABASE", test_db)
    monkeypatch.setattr(config, "MEDIA_ROOT", media_dir)
    monkeypatch.setattr(config, "POSTER_CACHE", poster_cache)
    monkeypatch.setattr(config, "BACKDROP_CACHE", backdrop_cache)
    init_db()

    flask_app = create_app()
    flask_app.config["TESTING"] = True
    with flask_app.test_client() as c:
        yield c


class TestSchemaMigration:
    def test_last_metadata_refresh_column_exists_after_init_db(self, client):
        db = get_db()
        cols = {r["name"] for r in db.execute("PRAGMA table_info(movies)").fetchall()}
        assert "last_metadata_refresh" in cols
        db.close()

    def test_scanner_setup_database_adds_column(self, tmp_path):
        import scanner
        db_path = tmp_path / "custom.db"
        conn = sqlite3.connect(db_path)
        scanner.setup_database(conn)
        cols = {r[1] for r in conn.execute("PRAGMA table_info(movies)").fetchall()}
        assert "last_metadata_refresh" in cols
        conn.close()


class TestMovieMetadataRefresh:
    def test_refresh_movie_metadata_updates_fields(self, client, monkeypatch):
        db = get_db()
        db.execute(
            """
            INSERT INTO movies (filename, title, year, tmdb_id, vote_average, runtime, details_json, last_metadata_refresh)
            VALUES ('Spider-Man.mkv', 'Spider-Man', 2002, 557, 7.0, 120, '{}', 0)
            """
        )
        db.commit()

        mock_details = {
            "id": 557,
            "title": "Spider-Man",
            "vote_average": 7.3,
            "runtime": 121,
            "overview": "Peter Parker is bitten by a genetically altered spider.",
            "genres": [{"name": "Action"}, {"name": "Sci-Fi"}],
            "release_date": "2002-05-01",
            "tagline": "With great power comes great responsibility.",
            "poster_path": "/spider_poster.jpg",
            "backdrop_path": "/spider_backdrop.jpg",
            "credits": {
                "cast": [{"name": "Tobey Maguire", "character": "Peter Parker", "profile_path": "/tobey.jpg"}],
                "crew": [{"name": "Sam Raimi", "job": "Director"}]
            },
            "release_dates": {
                "results": [{"iso_3166_1": "US", "release_dates": [{"certification": "PG-13"}]}]
            },
            "videos": {
                "results": [{"site": "YouTube", "type": "Trailer", "key": "TYMMOjB329E"}]
            }
        }

        mock_session = MagicMock()
        with patch("app.services.tmdb_service.get_movie_details", return_value=mock_details), \
             patch("app.services.tmdb_service.download_poster", return_value=True):
            row = db.execute("SELECT * FROM movies WHERE filename='Spider-Man.mkv'").fetchone()
            updated = refresh_movie_metadata(db, mock_session, "fake-token", row, force=True)
            assert updated is True

            updated_row = db.execute("SELECT * FROM movies WHERE filename='Spider-Man.mkv'").fetchone()
            assert updated_row["vote_average"] == 7.3
            assert updated_row["runtime"] == 121
            assert updated_row["genres"] == "Action, Sci-Fi"
            assert updated_row["last_metadata_refresh"] > 0

            details = json.loads(updated_row["details_json"])
            assert details["tagline"] == "With great power comes great responsibility."
            assert details["certification"] == "PG-13"
            assert details["trailer_key"] == "TYMMOjB329E"
            assert details["directors"] == ["Sam Raimi"]
            assert details["cast"][0]["name"] == "Tobey Maguire"

        db.close()

    def test_refresh_movie_metadata_throttling_respects_max_age(self, client):
        db = get_db()
        now = int(time.time())
        # Movie refreshed 10 minutes ago
        db.execute(
            """
            INSERT INTO movies (filename, title, tmdb_id, vote_average, last_metadata_refresh)
            VALUES ('Recent.mkv', 'Recent Movie', 100, 8.0, ?)
            """,
            (now - 600,)
        )
        db.commit()

        mock_session = MagicMock()
        with patch("app.services.tmdb_service.get_movie_details") as mock_get:
            row = db.execute("SELECT * FROM movies WHERE filename='Recent.mkv'").fetchone()
            # Under 4-hour max_age, should NOT query TMDb
            updated = refresh_movie_metadata(db, mock_session, "fake-token", row, force=False, max_age_seconds=14400)
            assert updated is False
            mock_get.assert_not_called()

            # When force=True, it SHOULD query TMDb
            mock_get.return_value = {"id": 100, "vote_average": 8.5}
            updated_forced = refresh_movie_metadata(db, mock_session, "fake-token", row, force=True)
            assert updated_forced is True
            mock_get.assert_called_once()

        db.close()

    def test_refresh_all_library_metadata(self, client):
        db = get_db()
        db.execute(
            """
            INSERT INTO movies (filename, title, tmdb_id, vote_average, last_metadata_refresh)
            VALUES
                ('Movie1.mkv', 'Movie 1', 101, 7.0, 0),
                ('Movie2.mkv', 'Movie 2', 102, 7.5, 0),
                ('Unindexed.mkv', 'Unindexed', NULL, NULL, NULL)
            """
        )
        db.commit()

        with patch("app.services.tmdb_service.load_token", return_value="fake-token"), \
             patch("app.services.tmdb_service.refresh_movie_metadata", return_value=True) as mock_refresh, \
             patch("time.sleep"):
            count = refresh_all_library_metadata(force=True, conn=db)
            assert count == 2
            assert mock_refresh.call_count == 2

        db.close()


class TestScannerAndApiIntegration:
    def test_api_scan_triggers_metadata_refresh(self, client):
        with patch("app.routes.api.trigger_library_scan", return_value=True) as mock_trigger:
            resp = client.post("/api/scan")
            assert resp.status_code == 200
            mock_trigger.assert_called_once_with(refresh_metadata=True, force_refresh=True)
            data = resp.json
            assert data["status"] == "scanning"

    def test_run_library_scan_invokes_refresh_when_flagged(self, client):
        with patch("scanner.scan", return_value=[]), \
             patch("app.services.tmdb_service.refresh_all_library_metadata") as mock_refresh:
            run_library_scan(refresh_metadata=True, force_refresh=True)
            mock_refresh.assert_called_once_with(force=True)

    def test_start_metadata_refresh_worker_disabled_in_tests(self):
        # pytest is in sys.modules, so it should not start any thread
        with patch("threading.Thread") as mock_thread:
            start_metadata_refresh_worker()
            mock_thread.assert_not_called()
