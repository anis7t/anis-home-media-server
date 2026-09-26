"""Tests for Phase 4 library and movie details JSON API endpoints."""
import json
import sqlite3
import pytest
from app import config, create_app, get_db, init_db


@pytest.fixture
def client(tmp_path, monkeypatch):
    """Create Flask test client with an isolated temporary database and media directory."""
    test_db = tmp_path / "test_api_movies.db"
    media_dir = tmp_path / "media"
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

    # Create dummy video files
    video1 = media_dir / "Movie_One.2026.mp4"
    video1.write_bytes(b"dummy video content for video 1")
    video2 = media_dir / "Movie_Two_No_Meta.2025.mkv"
    video2.write_bytes(b"dummy video content for video 2")
    video3 = media_dir / "Movie_Three_Watching.2024.mp4"
    video3.write_bytes(b"dummy video content for video 3")

    # Invalidate cached paths in media_service
    import app.services.media_service as media_service
    media_service._paths = (0, [])

    # Seed database
    db = get_db()
    details_json = json.dumps({
        "tagline": "The ultimate test.",
        "imdb_id": "tt9999999",
        "certification": "PG-13",
        "cast": [
            {"name": "Actor One", "character": "Hero", "profile_path": "/hero.jpg"},
            {"name": "Actor Two", "character": "Villain", "profile_path": None},
        ],
        "directors": ["Director A"],
        "writers": ["Writer B"],
        "production": ["Studio C"],
        "trailer_key": "abc123xyz",
    })

    db.execute(
        "INSERT INTO movies (filename, title, year, tmdb_id, overview, runtime, genres, vote_average, release_date, details_json, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            "Movie_One.2026.mp4",
            "Movie One",
            2026,
            12345,
            "An epic test adventure.",
            120,
            "Action, Sci-Fi",
            8.4,
            "2026-06-01",
            details_json,
            1750000000,
        )
    )

    db.execute(
        "INSERT INTO movies (filename, title, year, tmdb_id, overview, runtime, genres, vote_average, release_date, details_json, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            "Movie_Two_No_Meta.2025.mkv",
            "Movie Two No Meta",
            None,
            None,
            "",
            None,
            "",
            None,
            None,
            "",
            1750000000,
        )
    )

    db.execute(
        "INSERT INTO movies (filename, title, year, tmdb_id, overview, runtime, genres, vote_average, release_date, details_json, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            "Movie_Three_Watching.2024.mp4",
            "Movie Three Watching",
            2024,
            67890,
            "Watching progress movie.",
            90,
            "Drama",
            7.0,
            "2024-01-01",
            None,
            1750000000,
        )
    )

    # Add watch progress (Movie Three is in-progress: position=60, duration=300)
    db.execute(
        "INSERT INTO progress (filename, position, duration, updated_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP)",
        ("Movie_Three_Watching.2024.mp4", 60.0, 300.0)
    )
    # Movie One has position <= 10, so it should NOT be in watching
    db.execute(
        "INSERT INTO progress (filename, position, duration, updated_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP)",
        ("Movie_One.2026.mp4", 5.0, 7200.0)
    )

    db.commit()
    db.close()

    flask_app = create_app()
    flask_app.config["TESTING"] = True
    with flask_app.test_client() as c:
        yield c


def test_get_movies_structure(client):
    """GET /api/movies returns 200 with movies list, watching list, and total count."""
    resp = client.get('/api/movies')
    assert resp.status_code == 200
    data = resp.get_json()
    assert isinstance(data, dict)
    assert 'movies' in data
    assert 'watching' in data
    assert 'total' in data
    assert isinstance(data['movies'], list)
    assert isinstance(data['watching'], list)
    assert data['total'] == len(data['movies'])
    assert data['total'] >= 3


def test_get_movies_items_serialization(client):
    """GET /api/movies ensures item dictionaries are properly serialized and normalized."""
    resp = client.get('/api/movies')
    assert resp.status_code == 200
    data = resp.get_json()

    for item in data['movies']:
        assert 'filename' in item
        assert 'title' in item
        # Path object must NOT be leaked
        assert 'path' not in item
        # Year must be int or None
        assert item['year'] is None or isinstance(item['year'], int)
        # Rating must be float or None
        assert item['rating'] is None or isinstance(item['rating'], (int, float))
        # Runtime must be int or None
        assert item['runtime'] is None or isinstance(item['runtime'], int)
        # Percent must be non-negative
        assert item['percent'] >= 0


def test_get_movies_watching_subset(client):
    """GET /api/movies watching list satisfies the canonical in-progress criteria."""
    resp = client.get('/api/movies')
    assert resp.status_code == 200
    data = resp.get_json()

    # Movie Three should be in watching (position=60, duration=300)
    # Movie One should NOT be in watching (position=5)
    watching_filenames = [w['filename'] for w in data['watching']]
    assert "Movie_Three_Watching.2024.mp4" in watching_filenames
    assert "Movie_One.2026.mp4" not in watching_filenames

    for w in data['watching']:
        assert w['position'] > 10
        if w.get('duration'):
            assert w['position'] < w['duration'] - 10


def test_get_movie_details_404_on_unknown(client):
    """GET /api/movie/<filename> returns 404 for nonexistent files."""
    resp = client.get('/api/movie/nonexistent_file_definitely_does_not_exist_404.mp4')
    assert resp.status_code == 404


def test_get_movie_details_success_with_full_metadata(client):
    """GET /api/movie/<filename> returns 200 and complete schema for a movie with TMDb metadata."""
    resp = client.get('/api/movie/Movie_One.2026.mp4')
    assert resp.status_code == 200
    details = resp.get_json()

    assert 'movie' in details
    assert 'specs' in details
    assert 'extended' in details
    assert 'formatted_runtime' in details

    movie = details['movie']
    assert movie['filename'] == "Movie_One.2026.mp4"
    assert movie['title'] == "Movie One"
    assert movie['year'] == 2026
    assert movie['tmdb_id'] == 12345
    assert movie['rating'] == 8.4
    assert 'path' not in movie

    specs = details['specs']
    assert 'container' in specs
    assert specs['container'] == 'MP4'
    assert 'subtitles' in specs
    assert isinstance(specs['subtitles'], list)

    extended = details['extended']
    assert isinstance(extended, dict)
    assert extended['tagline'] == "The ultimate test."
    assert extended['certification'] == "PG-13"
    assert len(extended['cast']) == 2
    assert extended['cast'][0]['name'] == "Actor One"
    assert extended['directors'] == ["Director A"]
    assert extended['trailer_key'] == "abc123xyz"


def test_get_movie_details_defensive_degradation_without_metadata(client):
    """GET /api/movie/<filename> safely returns defaults when metadata/details_json are missing."""
    resp = client.get('/api/movie/Movie_Two_No_Meta.2025.mkv')
    assert resp.status_code == 200
    details = resp.get_json()

    movie = details['movie']
    assert movie['filename'] == "Movie_Two_No_Meta.2025.mkv"
    assert movie['year'] is None
    assert movie['rating'] is None
    assert movie['runtime'] is None

    # extended should be an empty dict, not None, and not crash
    assert isinstance(details['extended'], dict)
    assert details['extended'] == {}

    # specs should still report container correctly
    specs = details['specs']
    assert specs['container'] == 'MKV'
    assert isinstance(specs['subtitles'], list)
