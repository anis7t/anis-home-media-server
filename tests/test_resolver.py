"""Tests for forensic media resolution and anonymous/numeric file identification."""
import json
import sqlite3
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch

from app.services.media_resolver import (
    is_anonymous_name,
    find_movie_by_imdb_id,
    resolve_via_moviehash,
    resolve_via_container_tags,
    resolve_media,
)
import scanner


def test_is_anonymous_name():
    # Numeric filenames
    assert is_anonymous_name("1000403712") is True
    assert is_anonymous_name("9823412") is True
    assert is_anonymous_name("") is True
    assert is_anonymous_name(None) is True

    # Hex/UUID stems
    assert is_anonymous_name("30dd42a35963fefdb844530e650b21268f798f6e") is True
    assert is_anonymous_name("a1b2c3d4-e5f6-7890-abcd-ef1234567890") is True

    # Generic stems
    assert is_anonymous_name("vid_20260904_120344") is True
    assert is_anonymous_name("video_123") is True
    assert is_anonymous_name("mov_0001") is True
    assert is_anonymous_name("untitled") is True

    # Valid movie titles
    assert is_anonymous_name("Mayday") is False
    assert is_anonymous_name("Spider-Man Brand New Day") is False
    assert is_anonymous_name("Oculus") is False
    assert is_anonymous_name("Ghost in the Cell") is False


def test_find_movie_by_imdb_id():
    mock_session = MagicMock()
    token = "fake_token"

    # Mock successful TMDB find response
    mock_resp = {
        "movie_results": [
            {
                "id": 1137844,
                "title": "Mayday",
                "release_date": "2026-09-03",
                "poster_path": "/poster.jpg"
            }
        ]
    }

    with patch("scanner.tmdb_get", return_value=mock_resp):
        res = find_movie_by_imdb_id(mock_session, token, "28014327")
        assert res is not None
        assert res["title"] == "Mayday"
        assert res["id"] == 1137844

        # With leading 'tt'
        res2 = find_movie_by_imdb_id(mock_session, token, "tt28014327")
        assert res2 is not None
        assert res2["id"] == 1137844


def test_resolve_via_moviehash(tmp_path):
    # Create dummy video file
    dummy = tmp_path / "1000403712.mkv"
    dummy.write_bytes(b"0" * 150000)

    mock_session = MagicMock()
    token = "fake_token"

    # Mock OpenSubtitles API response
    os_response = MagicMock()
    os_response.status_code = 200
    os_response.json.return_value = [
        {
            "MatchedBy": "moviehash",
            "MovieName": "Mayday",
            "MovieYear": "2026",
            "IDMovieImdb": "28014327"
        }
    ]
    mock_session.get.return_value = os_response

    mock_tmdb_movie = {
        "id": 1137844,
        "title": "Mayday",
        "release_date": "2026-09-03",
        "poster_path": "/poster.jpg"
    }

    with patch("app.services.media_resolver.compute_opensubtitles_hash", return_value=("1f5a9687aa065a11", 150000)), \
         patch("app.services.media_resolver.find_movie_by_imdb_id", return_value=mock_tmdb_movie):
        movie, src = resolve_via_moviehash(dummy, mock_session, token)
        assert movie is not None
        assert movie["title"] == "Mayday"
        assert movie["id"] == 1137844
        assert "imdb:tt28014327" in src


def test_resolve_via_container_tags(tmp_path):
    dummy = tmp_path / "unknown_123.mkv"
    dummy.write_bytes(b"0" * 1000)

    mock_session = MagicMock()
    token = "fake_token"

    ffprobe_meta = {
        "format": {
            "tags": {
                "title": "Mayday (2026)"
            }
        },
        "streams": []
    }

    mock_proc = MagicMock()
    mock_proc.returncode = 0
    mock_proc.stdout = json.dumps(ffprobe_meta)

    mock_tmdb_movie = {
        "id": 1137844,
        "title": "Mayday",
        "release_date": "2026-09-03"
    }

    with patch("subprocess.run", return_value=mock_proc), \
         patch("scanner.find_movie", return_value=mock_tmdb_movie):
        movie, src = resolve_via_container_tags(dummy, mock_session, token)
        assert movie is not None
        assert movie["title"] == "Mayday"
        assert "container_tags" in src


def test_scan_single_file_numeric_resolution(tmp_path):
    dummy = tmp_path / "1000403712.mkv"
    dummy.write_bytes(b"0" * 200000)

    db_path = tmp_path / "test.db"
    conn = sqlite3.connect(db_path)
    scanner.setup_database(conn)

    mock_session = MagicMock()
    token = "fake_token"

    mock_resolved_movie = {
        "id": 1137844,
        "title": "Mayday",
        "release_date": "2026-09-03"
    }

    mock_details = {
        "id": 1137844,
        "title": "Mayday",
        "release_date": "2026-09-03",
        "overview": "Cold war navy pilot adventure.",
        "poster_path": "/mayday_poster.jpg",
        "backdrop_path": "/mayday_backdrop.jpg",
        "runtime": 110,
        "genres": [{"name": "Action"}, {"name": "Comedy"}],
        "vote_average": 7.9,
    }

    with patch("scanner.load_token", return_value=token), \
         patch("app.services.media_resolver.resolve_media", return_value=(mock_resolved_movie, "moviehash:imdb:tt28014327")), \
         patch("scanner.get_movie_details", return_value=mock_details), \
         patch("posters.download_poster", return_value=True):

        res = scanner.scan_single_file(dummy, conn=conn, session=mock_session, token=token, media_root=tmp_path)
        assert res is not None
        assert res["title"] == "Mayday"
        assert res["id"] == 1137844

        # Verify DB was populated with resolved title, not numeric name
        row = conn.execute("SELECT title, tmdb_id, year, poster_path FROM movies WHERE filename=?", ("1000403712.mkv",)).fetchone()
        assert row is not None
        assert row[0] == "Mayday"
        assert row[1] == 1137844
        assert row[2] == 2026
        assert row[3] == "/mayday_poster.jpg"

    conn.close()

