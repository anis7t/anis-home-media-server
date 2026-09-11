"""Tests for forensic media resolution and anonymous/numeric file identification."""
import json
import sqlite3
from unittest.mock import MagicMock, patch

from app.services.media_resolver import (
    is_anonymous_name,
    find_movie_by_imdb_id,
    resolve_via_moviehash,
    resolve_via_container_tags,
    resolve_via_sidecar_subtitles,
    resolve_media,
)
import scanner


def test_is_anonymous_name():
    assert is_anonymous_name("1000403712") is True
    assert is_anonymous_name("9823412") is True
    assert is_anonymous_name("") is True
    assert is_anonymous_name(None) is True
    assert is_anonymous_name("30dd42a35963fefdb844530e650b21268f798f6e") is True
    assert is_anonymous_name("a1b2c3d4-e5f6-7890-abcd-ef1234567890") is True
    assert is_anonymous_name("vid_20260904_120344") is True
    assert is_anonymous_name("video_123") is True
    assert is_anonymous_name("Mayday") is False
    assert is_anonymous_name("Spider-Man Brand New Day") is False


def test_find_movie_by_imdb_id():
    session = MagicMock()
    with patch("scanner.tmdb_get", return_value={"movie_results": [{"id": 1137844, "title": "Mayday"}]}):
        assert find_movie_by_imdb_id(session, "token", "28014327")["title"] == "Mayday"
        assert find_movie_by_imdb_id(session, "token", "tt28014327")["id"] == 1137844


def test_resolve_via_moviehash(tmp_path):
    dummy = tmp_path / "1000403712.mkv"
    dummy.write_bytes(b"0" * 150000)
    response = MagicMock(status_code=200)
    response.json.return_value = [{"MovieName": "Mayday", "MovieYear": "2026", "IDMovieImdb": "28014327"}]
    session = MagicMock()
    session.get.return_value = response
    movie = {"id": 1137844, "title": "Mayday", "release_date": "2026-09-03"}
    with patch("app.services.media_resolver.compute_opensubtitles_hash", return_value=("1f5a9687aa065a11", 150000)), \
         patch("app.services.media_resolver.find_movie_by_imdb_id", return_value=movie), \
         patch("app.services.media_resolver._runtime_score", return_value=1.5):
        resolved, src = resolve_via_moviehash(dummy, session, "token")
    assert resolved["title"] == "Mayday"
    assert "imdb:tt28014327" in src


def test_resolve_via_container_tags(tmp_path):
    dummy = tmp_path / "unknown_123.mkv"
    dummy.write_bytes(b"0" * 1000)
    proc = MagicMock(returncode=0, stdout=json.dumps({"format": {"tags": {"title": "Mayday (2026)"}}, "streams": []}))
    movie = {"id": 1137844, "title": "Mayday", "release_date": "2026-09-03"}
    with patch("subprocess.run", return_value=proc), patch("scanner.find_movie", return_value=movie):
        resolved, src = resolve_via_container_tags(dummy, MagicMock(), "token")
    assert resolved["title"] == "Mayday"
    assert "container_tags" in src


def test_sidecar_subtitle_filename_is_independent_evidence(tmp_path):
    movie_file = tmp_path / "1000403712.mkv"
    movie_file.write_bytes(b"0")
    (tmp_path / "Coyote vs Acme (2023).srt").write_text("1\n00:00:01,000 --> 00:00:02,000\nHello\n")
    movie = {"id": 123, "title": "Coyote vs. Acme", "release_date": "2023-04-07"}
    with patch("scanner.find_movie", return_value=movie):
        resolved, src = resolve_via_sidecar_subtitles(movie_file, MagicMock(), "token")
    assert resolved["title"] == "Coyote vs. Acme"
    assert "sidecar_subtitle" in src


def test_moviehash_alone_does_not_override_conflicting_evidence(tmp_path):
    dummy = tmp_path / "1000403712.mkv"
    dummy.write_bytes(b"0" * 200000)
    wrong = {"id": 1, "title": "Behind the Spanish Lines"}
    right = {"id": 2, "title": "Coyote vs. Acme"}
    with patch("app.services.media_resolver.resolve_via_container_tags", return_value=(right, "container_tags:Coyote vs Acme")), \
         patch("app.services.media_resolver.resolve_via_sidecar_subtitles", return_value=(None, None)), \
         patch("app.services.media_resolver.resolve_via_moviehash", return_value=(wrong, "moviehash:imdb:tt-wrong")), \
         patch("app.services.media_resolver.resolve_via_visual_ocr", return_value=(None, None)):
        resolved, src = resolve_media(dummy, MagicMock(), "token")
    assert resolved["title"] == "Coyote vs. Acme"
    assert "container_tags" in src


def test_ambiguous_forensic_evidence_returns_unresolved(tmp_path):
    dummy = tmp_path / "1000403712.mkv"
    dummy.write_bytes(b"0" * 200000)
    first = {"id": 1, "title": "Movie One"}
    second = {"id": 2, "title": "Movie Two"}
    with patch("app.services.media_resolver.resolve_via_container_tags", return_value=(None, None)), \
         patch("app.services.media_resolver.resolve_via_sidecar_subtitles", return_value=(None, None)), \
         patch("app.services.media_resolver.resolve_via_moviehash", return_value=(first, "moviehash:first")), \
         patch("app.services.media_resolver.resolve_via_visual_ocr", return_value=(second, "visual_ocr:second")):
        resolved, src = resolve_media(dummy, MagicMock(), "token")
    assert resolved is None
    assert src is None


def test_scan_single_file_numeric_resolution(tmp_path):
    dummy = tmp_path / "1000403712.mkv"
    dummy.write_bytes(b"0" * 200000)
    conn = sqlite3.connect(tmp_path / "test.db")
    scanner.setup_database(conn)
    mock_resolved_movie = {"id": 1137844, "title": "Mayday", "release_date": "2026-09-03"}
    mock_details = {
        "id": 1137844, "title": "Mayday", "release_date": "2026-09-03",
        "overview": "Cold war navy pilot adventure.", "poster_path": "/mayday_poster.jpg",
        "backdrop_path": "/mayday_backdrop.jpg", "runtime": 110,
        "genres": [{"name": "Action"}], "vote_average": 7.9,
    }
    with patch("scanner.load_token", return_value="fake_token"), \
         patch("app.services.media_resolver.resolve_media", return_value=(mock_resolved_movie, "consensus:container_tags:Mayday,moviehash:imdb:tt28014327")), \
         patch("scanner.get_movie_details", return_value=mock_details), \
         patch("posters.download_poster", return_value=True):
        result = scanner.scan_single_file(dummy, conn=conn, session=MagicMock(), token="fake_token", media_root=tmp_path)
    assert result["title"] == "Mayday"
    row = conn.execute("SELECT title, tmdb_id, year FROM movies WHERE filename=?", ("1000403712.mkv",)).fetchone()
    assert row == ("Mayday", 1137844, 2026)
    conn.close()
