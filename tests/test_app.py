import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

_orig_media_root_env = os.environ.get("MEDIA_SERVER_MEDIA_ROOT")
_orig_database_env = os.environ.get("MEDIA_SERVER_DATABASE")
TMP = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
os.environ["MEDIA_SERVER_MEDIA_ROOT"] = TMP.name
os.environ["MEDIA_SERVER_DATABASE"] = str(Path(TMP.name) / "media.db")
import app

class MediaServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.video = Path(TMP.name) / "Example.2026.mp4"
        cls.video.write_bytes(b"0123456789")
        (Path(TMP.name) / "Example.2026.en.srt").write_text("1\n00:00:00,000 --> 00:00:01,000\nHello\n")
        app.init_db(); cls.client = app.app.test_client()

    @classmethod
    def tearDownClass(cls):
        if _orig_media_root_env is not None:
            os.environ["MEDIA_SERVER_MEDIA_ROOT"] = _orig_media_root_env
        else:
            os.environ.pop("MEDIA_SERVER_MEDIA_ROOT", None)
        if _orig_database_env is not None:
            os.environ["MEDIA_SERVER_DATABASE"] = _orig_database_env
        else:
            os.environ.pop("MEDIA_SERVER_DATABASE", None)
        import importlib
        import app.config
        importlib.reload(app.config)
        app.config.MEDIA_ROOT = app.config.MEDIA_ROOT
        app.config.DATABASE = app.config.DATABASE
        app.init_db()
    def test_library_and_pwa(self):
        self.assertEqual(self.client.get('/').status_code, 200)
        self.assertEqual(self.client.get('/manifest.webmanifest').status_code, 200)
    def test_ranges(self):
        url='/media/Example.2026.mp4'
        response=self.client.get(url, headers={'Range':'bytes=2-5'})
        self.assertEqual(response.status_code, 206); self.assertEqual(response.data,b'2345')
        self.assertEqual(response.headers['Content-Range'],'bytes 2-5/10')
        self.assertEqual(self.client.get(url,headers={'Range':'bytes=100-101'}).status_code,416)
    def test_subtitles_and_progress(self):
        self.assertIn(b'WEBVTT',self.client.get('/subtitles/Example.2026.mp4/Example.2026.en.srt').data)
        self.assertEqual(self.client.post('/api/progress',json={'filename':'Example.2026.mp4','position':15,'duration':10}).status_code,200)
        self.assertEqual(self.client.get('/api/progress?filename=Example.2026.mp4').json['position'],10)

    def test_subdirectory_subtitles_delivery_and_language_detection(self):
        sub_dir = Path(TMP.name) / "SubDir Movie.2026"
        sub_dir.mkdir(parents=True, exist_ok=True)
        movie_file = sub_dir / "Movie.2026.mkv"
        movie_file.write_bytes(b"dummy mkv video content")
        sub_file = sub_dir / "Movie.2026.srt"
        sub_file.write_text("1\n00:00:01,000 --> 00:00:03,000\nHello and welcome to the show.\n", encoding="utf-8")

        # Verify delivery via route /subtitles/<path:filename>/<name>
        rel_movie = "SubDir Movie.2026/Movie.2026.mkv"
        res = self.client.get(f"/subtitles/{rel_movie}/Movie.2026.srt")
        self.assertEqual(res.status_code, 200)
        self.assertIn(b"WEBVTT", res.data)
        self.assertIn(b"Hello and welcome to the show.", res.data)

        # Verify tracks() detects language from text as 'en' and marks it default
        from app.services.subtitles_service import tracks
        trks = tracks(movie_file)
        self.assertTrue(len(trks) >= 1)
        self.assertEqual(trks[0]['lang'], 'en')
        self.assertEqual(trks[0]['label'], 'English (Local)')
        self.assertTrue(trks[0]['default'])
    def test_new_media_files_are_discovered_immediately(self):
        app._paths = (time.monotonic(), [Path(TMP.name) / 'Example.2026.mp4'])
        new_file = Path(TMP.name) / 'Late.2026.mp4'
        new_file.write_bytes(b'9876543210')
        self.assertIn('Late.2026.mp4', [p.name for p in app.video_paths()])
    def test_watch_page_has_single_script_block(self):
        html = self.client.get('/watch/Example.2026.mp4').data.decode()
        self.assertEqual(html.count('</script>'), 1)
        self.assertIn("const filename", html)
        self.assertIn("pagehide',save);let mediaDuration", html)
        self.assertIn('timelineDuration', html)
        self.assertIn("status==='ready'", html)
    def test_watch_page_handles_initial_pts_gap_and_smart_seek(self):
        html = self.client.get('/watch/Example.2026.mp4').data.decode()
        self.assertIn('jumpStartGap', html)
        self.assertIn('nudgeOffset:0.1', html)
        self.assertIn('needsTranscodeWait', html)
        # Ensure the final active seek.oninput is the smart handler with gap avoidance
        last_seek = html[html.rfind('seek.oninput'):html.rfind('seek.oninput') + 150]
        self.assertIn('v.buffered.start(0)', last_seek)
    def test_hls_cache_route_is_generic_for_new_mkv_files(self):
        movie = Path(TMP.name) / 'New.Movie.2026.mkv'
        movie.write_bytes(b'new media')
        with patch('app.probe_media', return_value={'streams': [{'codec_type': 'video', 'codec_name': 'h264', 'width': 1920}]}), patch('app.subprocess.Popen'):
            response = self.client.get('/hls/New.Movie.2026.mkv/playlist.m3u8')
        self.assertEqual(response.status_code, 200)
        self.assertIn(b'#EXTM3U', response.data)
    def test_cleanup_keeps_valid_part_files_and_prunes_orphans(self):
        transcode_dir = Path(TMP.name) / 'cache' / 'transcodes'
        transcode_dir.mkdir(parents=True, exist_ok=True)
        final = transcode_dir / 'actual.mp4'
        final.write_bytes(b'final')
        valid_part = transcode_dir / 'actual.part.mp4'
        valid_part.write_bytes(b'partial')
        stale_part = transcode_dir / 'stale.part.mp4'
        stale_part.write_bytes(b'stale')
        stale_part.touch()
        old_time = time.time() - 7200
        os.utime(stale_part, (old_time, old_time))
        orig_cache_dir = getattr(app, 'CACHE_DIR', None)
        try:
            app.CACHE_DIR = Path(TMP.name) / 'cache'
            app.cleanup_cache()
            self.assertTrue(final.exists())
            self.assertTrue(valid_part.exists())
            self.assertFalse(stale_part.exists())
        finally:
            if orig_cache_dir is not None:
                app.CACHE_DIR = orig_cache_dir
    def test_transcode_uses_separate_locks_for_direct_and_compat_modes(self):
        app.TRANSCODE_LOCKS.clear()
        self.assertIsNot(app.TRANSCODE_LOCKS.setdefault('Example.2026.mp4:direct', __import__('threading').Lock()),
                         app.TRANSCODE_LOCKS.setdefault('Example.2026.mp4:compat', __import__('threading').Lock()))
    def test_compat_and_hls_transcodes_use_faster_optimized_settings(self):
        compat = app.compat_transcode_args(vaapi_available=False)
        hls = app.hls_transcode_args(vaapi_available=False)
        self.assertIn('-preset', compat)
        self.assertIn('superfast', compat)
        self.assertIn('-crf', compat)
        self.assertEqual(compat[compat.index('-crf') + 1], '23')
        self.assertIn('scale=-2:1080,format=yuv420p', compat)
        self.assertIn('-preset', hls)
        self.assertIn('superfast', hls)
        self.assertIn('-crf', hls)
        self.assertEqual(hls[hls.index('-crf') + 1], '23')
        self.assertIn('scale=-2:1080,format=yuv420p', hls)
    def test_transcode_is_safe_when_ffmpeg_is_unavailable(self):
        with patch('app.which', return_value=None):
            response = self.client.get('/transcode/Example.2026.mp4')
        self.assertEqual(response.status_code, 503)
    def test_vaapi_is_disabled_by_default_for_stability(self):
        with patch.dict(os.environ, {}):
            os.environ.pop('MEDIA_SERVER_ENABLE_VAAPI', None)
            self.assertFalse(app.is_vaapi_enabled())
    def test_transcode_status_hls_mode_reports_progress_and_eta(self):
        movie = Path(TMP.name) / 'StatusHls.2026.mkv'
        movie.write_bytes(b'video content for status')
        hls_dir = app.hls_cache_dir(movie)
        hls_dir.mkdir(parents=True, exist_ok=True)
        hls_prog = hls_dir / 'hls.progress'
        hls_prog.write_text('out_time_ms=60000000\nspeed=1.5x\n')
        with patch('app.probe_media', return_value={'format': {'duration': '120.0'}}):
            res = self.client.get('/api/transcode-status/StatusHls.2026.mkv?mode=hls')
        self.assertEqual(res.status_code, 200)
        data = res.json
        self.assertEqual(data['status'], 'building')
        self.assertAlmostEqual(data['percent'], 50.0, places=1)
        self.assertEqual(data['encoded'], 60.0)
        self.assertEqual(data['speed'], 1.5)
        self.assertAlmostEqual(data['remaining'], 40.0, places=1)
    def test_mkv_watch_page_triggers_hls_directly_and_not_remux(self):
        mkv = Path(TMP.name) / 'Spider.2026.mkv'
        mkv.write_bytes(b'mkv content')
        html = self.client.get('/watch/Spider.2026.mkv').data.decode()
        self.assertIn("if(!/\\.(mp4|m4v|webm)$/i.test(filename)){startHls();}", html)
        self.assertNotIn("startSource('remux')", html)
    def test_scanner_parse_filename_handles_complex_releases_and_copy_prefix(self):
        import scanner
        self.assertEqual(
            scanner.parse_filename(Path('Copy of Satluj.2026.1080p.HEVC.Hindi.WEB-DL.5.1.ESub.x265-HDHub4u.Ms (1).mkv')),
            ('Satluj', 2026)
        )
        self.assertEqual(
            scanner.parse_filename(Path('Ghost.in.the.Cell.2026.2160p.NF.WEB-DL.DDP5.1.H.265-PandaQT.mkv')),
            ('Ghost in the Cell', 2026)
        )
    def test_api_scan_endpoint_returns_json_status(self):
        with patch('app.run_library_scan'):
            res = self.client.post('/api/scan')
            self.assertEqual(res.status_code, 200)
            data = res.json
            self.assertIn('status', data)
            self.assertIn('busy', data)
    def test_homepage_includes_scan_button(self):
        html = self.client.get('/').data.decode()
        self.assertIn('id="scanBtn"', html)
        self.assertIn('/api/scan', html)
    def test_tmdb_poster_calls_downloader_if_missing(self):
        db = app.get_db()
        db.execute("INSERT OR REPLACE INTO movies(filename,tmdb_id,poster_path) VALUES('Mock.mkv', 999999, '/mock.jpg')")
        db.commit()
        db.close()
        with patch('posters.download_poster') as mock_dl:
            res = self.client.get('/tmdb-poster/999999')
            mock_dl.assert_called_once_with(999999, '/mock.jpg')
    def test_srt_to_vtt_conversion(self):
        srt = "1\n00:01:23,456 --> 00:01:28,789\nHello subtitle world!\n"
        vtt = app.srt_to_vtt(srt)
        self.assertTrue(vtt.startswith("WEBVTT\n\n"))
        self.assertIn("00:01:23.456 --> 00:01:28.789", vtt)
    def test_compute_opensubtitles_hash(self):
        test_file = Path(TMP.name) / "test_hash.bin"
        test_file.write_bytes(b"\x00" * 200000)
        h, sz = app.compute_opensubtitles_hash(test_file)
        self.assertEqual(sz, 200000)
        self.assertIsNotNone(h)
        self.assertEqual(len(h), 16)
    def test_embedded_subtitle_route_and_extraction(self):
        def fake_run(*args, **kwargs):
            cmd = args[0]
            out_file = Path(cmd[-1])
            out_file.write_text("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nEmbedded caption")
            class FakeRes:
                returncode = 0
            return FakeRes()
        with patch('subprocess.run', side_effect=fake_run):
            res = self.client.get('/subtitles/embedded/Example.2026.mp4/2.vtt')
            self.assertEqual(res.status_code, 200)
            self.assertIn(b"Embedded caption", res.data)
            self.assertEqual(res.content_type, 'text/vtt; charset=utf-8')
    def test_online_subtitle_route(self):
        with patch('app.fetch_online_subtitle') as mock_fetch:
            fake_vtt = Path(TMP.name) / "cache" / "subtitles" / "online" / "fake.vtt"
            fake_vtt.parent.mkdir(parents=True, exist_ok=True)
            fake_vtt.write_text("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nOnline caption")
            mock_fetch.return_value = fake_vtt
            res = self.client.get('/subtitles/online/Example.2026.mp4.vtt')
            self.assertEqual(res.status_code, 200)
            self.assertIn(b"Online caption", res.data)
    def test_api_subtitles_route(self):
        res = self.client.get('/api/subtitles/Example.2026.mp4')
        self.assertEqual(res.status_code, 200)
        self.assertIn('tracks', res.json)
        self.assertTrue(len(res.json['tracks']) >= 1)
        self.assertEqual(res.json['tracks'][0]['lang'], 'en')
    def test_player_ui_subtitle_controls_and_modal(self):
        html = self.client.get('/watch/Example.2026.mp4').data.decode()
        self.assertIn('id="ccBtn"', html)
        self.assertIn('id="subSettingsBtn"', html)
        self.assertIn('id="subSettingsModal"', html)
        self.assertIn('id="subTrackSelect"', html)
        self.assertIn('id="subColorSelect"', html)
        self.assertIn('id="subBgSelect"', html)
        self.assertIn('id="subSizeSelect"', html)
        self.assertIn('id="subPosSelect"', html)
        self.assertIn('video::cue', html)
        self.assertIn('toggleCC()', html)
        self.assertIn('applySubStyles()', html)
        self.assertIn('controlsVisibleAtInteractionStart', html)
    def test_cache_status_and_subtitle_scale_coexist(self):
        mkv = Path(TMP.name) / 'SubtitleMkv.2026.mkv'
        mkv.write_bytes(b'dummy content')
        (Path(TMP.name) / 'SubtitleMkv.2026.en.srt').write_text("1\n00:00:00,000 --> 00:00:01,000\nHi\n")
        html = self.client.get('/watch/SubtitleMkv.2026.mkv').data.decode()
        self.assertIn('id="cacheStatus"', html)
        self.assertIn('id="cacheMessage"', html)
        self.assertIn('id="subSettingsModal"', html)
        self.assertIn('clamp(22px, 2.8vw, 36px)', html)
        self.assertIn('SUB_SIZE_MAP', html)
    def test_player_aspect_ratio_controls_and_hud(self):
        html = self.client.get('/watch/Example.2026.mp4').data.decode()
        self.assertIn('id="aspectBtn"', html)
        # Verify aspect ratio button uses an intuitive SVG framing icon instead of raw text
        self.assertIn('<button id="aspectBtn" type="button" title="Aspect ratio (a)" aria-label="Aspect ratio"><svg', html)
        self.assertNotIn('>Fit</button>', html)
        self.assertNotIn('>Orig</button>', html)
        self.assertIn('id="playerHud"', html)
        self.assertIn('ASPECT_MODES', html)
        self.assertIn('nextAspect()', html)
        self.assertIn('applyAspect', html)
        self.assertIn('aspect-fit', html)
        self.assertIn('aspect-crop', html)
        self.assertIn('aspect-stretch', html)
        self.assertIn('aspect-16-9', html)
        self.assertIn('aspect-4-3', html)
        self.assertIn('aspect-orig', html)

    def test_player_seek_time_row_and_elapsed_remaining_display(self):
        html = self.client.get('/watch/Example.2026.mp4').data.decode()
        # Verify seek-time-row is situated above the seek bar
        self.assertIn('class="seek-time-row"', html)
        self.assertIn('id="timeElapsed"', html)
        self.assertIn('id="timeTotal"', html)
        # Check order: seek-time-row appears before seek input
        time_row_pos = html.find('class="seek-time-row"')
        seek_input_pos = html.find('id="seek"')
        self.assertTrue(time_row_pos < seek_input_pos)
        # Verify backward-compatibility: #time still exists in controls-row with hidden attribute
        self.assertIn('<span id="time" hidden>0:00 / 0:00</span>', html)
        # Verify JS time update logic and total/remaining toggle
        self.assertIn('updateTimeDisplay', html)
        self.assertIn('showRemainingTime', html)
        self.assertIn('media_show_remaining', html)
        self.assertIn('.seek-time-row{display:flex;justify-content:space-between;align-items:center;', html)

    def test_player_screen_rotation_button_and_shortcuts(self):
        html = self.client.get('/watch/Example.2026.mp4').data.decode()
        # Verify rotateBtn is present in controls-row with rotation SVG
        self.assertIn('id="rotateBtn"', html)
        self.assertIn('<button id="rotateBtn" type="button" title="Rotate screen (r)" aria-label="Rotate screen"><svg', html)
        # Verify direct child in controls-row and Rule 8 invariant
        controls_row = html.split('<div class="controls-row">')[1].split('</div>')[0]
        self.assertIn('id="rotateBtn"', controls_row)
        self.assertNotIn('<div', controls_row)
        # Verify JS rotation function and keyboard shortcut
        self.assertIn('toggleScreenRotation', html)
        self.assertIn("e.key==='r'||e.key==='R'", html)
        self.assertIn('<kbd>r</kbd>', html)
        self.assertIn('Rotate Screen', html)
        self.assertIn('video.rotate-90', html)
    def test_player_touch_gestures_and_double_tap_ripples(self):
        html = self.client.get('/watch/Example.2026.mp4').data.decode()
        self.assertIn('id="seekRippleLeft"', html)
        self.assertIn('id="seekRippleRight"', html)
        self.assertIn('id="seekRippleLeftSec"', html)
        self.assertIn('id="seekRippleRightSec"', html)
        self.assertIn('showRipple', html)
        self.assertIn('accumulatedSide', html)
        self.assertIn('user-scalable=no', html)
    def test_mobile_viewport_and_safe_area_styles(self):
        html = self.client.get('/watch/Example.2026.mp4').data.decode()
        self.assertIn('100dvh', html)
        self.assertIn('env(safe-area-inset-bottom)', html)
        self.assertIn('@media(max-width:768px),(max-height:500px)', html)
    def test_player_white_seekbar_progress_and_styling(self):
        html = self.client.get('/watch/Example.2026.mp4').data.decode()
        self.assertIn('--seek-pct', html)
        self.assertIn('updateSeekFill', html)
        self.assertIn('linear-gradient(to right,#ffffff var(--seek-pct', html)
        self.assertIn('::-moz-range-progress{background:#ffffff', html)
        self.assertIn('::-webkit-slider-thumb{-webkit-appearance:none;appearance:none;width:14px;height:14px;border-radius:50%;background:#ffffff', html)
    def test_watch_page_media_description_section_and_layout(self):
        html = self.client.get('/watch/Example.2026.mp4').data.decode()
        self.assertIn('class="watch-info"', html)
        self.assertIn('class="detail-grid"', html)
        self.assertIn('class="overview"', html)
        self.assertIn('class="facts"', html)
        self.assertIn('Example 2026', html)
        self.assertIn('overflow-y:auto', html)
        self.assertIn('.watch-info{max-width:1260px;margin:2.5rem auto 4.5rem;padding:0 1.5rem}', html)
    def test_player_replay_button_and_top_right_fullscreen(self):
        html = self.client.get('/watch/Example.2026.mp4').data.decode()
        # Fullscreen button is inside #shell top-right and outside controls-row, using vector SVG
        self.assertIn('<button id="full" type="button" title="Fullscreen (f)"><svg viewBox="0 0 24 24"', html)
        self.assertIn('FS_ENTER_SVG', html)
        self.assertIn('FS_EXIT_SVG', html)
        self.assertIn('#full svg{width:20px;height:20px;', html)
        self.assertIn('#full{position:absolute;z-index:3;top:1.1rem;right:1.2rem', html)
        self.assertIn('#shell.show #controls,#shell.show .watch-back,#shell.show #full{opacity:1;pointer-events:auto}', html)
        # Replay / restart button is the FIRST button inside controls-row
        self.assertIn('<div class="controls-row"><button id="restartBtn" type="button" title="Play from beginning">', html)
        self.assertIn('<button id="restartBtn" type="button" title="Play from beginning"><svg viewBox="0 0 24 24"', html)
        self.assertIn('#restartBtn svg{transition:transform .2s ease}', html)
        # Fullscreen button is not inside controls-row
        controls_row = html.split('<div class="controls-row">')[1].split('</div>')[0]
        self.assertIn('id="restartBtn"', controls_row)
        self.assertIn('id="play"', controls_row)
        self.assertNotIn('id="full"', controls_row)
        self.assertTrue(controls_row.index('id="restartBtn"') < controls_row.index('id="play"'))
        # JS logic & shortcuts
        self.assertIn('function restartFromBeginning()', html)
        self.assertIn('restartBtn.onclick', html)
        self.assertIn("e.code==='Home'||e.key==='0'", html)
        self.assertIn("e.key==='f'||e.key==='F'", html)
        self.assertIn("document.addEventListener('fullscreenchange'", html)

    def test_details_page_rich_features(self):
        import json
        rich_video = Path(TMP.name) / "RichMovie.2026.mp4"
        rich_video.write_bytes(b"0123456789")
        db = app.get_db()
        test_details = {
            "tagline": "A test tagline for movie.",
            "imdb_id": "tt1234567",
            "certification": "PG-13",
            "cast": [
                {"name": "Actor One", "character": "Hero", "profile_path": "/path1.jpg"},
                {"name": "Actor Two", "character": "Sidekick", "profile_path": None}
            ],
            "directors": ["Famous Director"],
            "writers": ["Great Writer"],
            "production": ["Top Studio"],
            "trailer_key": "abc123xyz"
        }
        db.execute(
            "INSERT OR REPLACE INTO movies (filename, title, year, runtime, vote_average, details_json) VALUES (?, ?, ?, ?, ?, ?)",
            ("RichMovie.2026.mp4", "Rich Movie", 2026, 125, 8.4, json.dumps(test_details))
        )
        db.commit()
        db.close()

        resp = self.client.get('/movie/RichMovie.2026.mp4')
        self.assertEqual(resp.status_code, 200)
        html = resp.data.decode()

        # Hero & metadata
        self.assertIn('Rich Movie', html)
        self.assertIn('“A test tagline for movie.”', html)
        self.assertIn('2 hr 5 min', html)
        self.assertIn('PG-13', html)
        self.assertIn('★ 8.4', html)
        self.assertIn('id="endsAtBadge"', html)
        self.assertIn('id="watchStatusBadge"', html)

        # Action bar buttons
        self.assertIn('id="playBtn"', html)
        self.assertIn('id="replayBtn"', html)
        self.assertIn('replay=1', html)
        self.assertIn('id="watchToggleBtn"', html)
        self.assertIn('id="trailerBtn"', html)
        self.assertIn('https://www.imdb.com/title/tt1234567/', html)

        # Media technical specs card
        self.assertIn('class="media-specs-card"', html)
        self.assertIn('class="specs-grid"', html)
        self.assertIn('MP4', html)

        # Cast rail
        self.assertIn('class="cast-rail"', html)
        self.assertIn('Actor One', html)
        self.assertIn('Hero', html)
        self.assertIn('Actor Two', html)
        self.assertIn('Sidekick', html)
        self.assertIn('Famous Director', html)
        self.assertIn('Great Writer', html)
        self.assertIn('Top Studio', html)

        # Trailer modal
        self.assertIn('id="trailerModal"', html)
        self.assertIn('id="trailerIframe"', html)
        self.assertIn('abc123xyz', html)

    def test_helpers_format_and_specs(self):
        self.assertEqual(app.format_runtime_display(148), "2 hr 28 min")
        self.assertEqual(app.format_runtime_display(60), "1 hr")
        self.assertEqual(app.format_runtime_display(45), "45 min")
        self.assertEqual(app.format_runtime_display(0), "")
        self.assertIn("MB", app.format_bytes_display(15 * 1024 * 1024))
        self.assertIn("GB", app.format_bytes_display(2 * 1024 * 1024 * 1024))

    def test_details_page_mobile_overflow_prevention(self):
        self.assertIn("html.details-html, body.details-page{width:100%;max-width:100%;overflow-x:hidden", app.CSS)
        self.assertIn(".media-specs-card{background:rgba(18,20,28,.75);backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px);border:1px solid rgba(255,255,255,.1);border-radius:12px;padding:1.2rem 1.4rem;margin-top:1.8rem;box-shadow:0 8px 30px rgba(0,0,0,.4);width:100%;max-width:100%;min-width:0;box-sizing:border-box;overflow:hidden}", app.CSS)
        self.assertIn("min-width:0", app.CSS)
        self.assertIn("overscroll-behavior-x:contain", app.CSS)
        self.assertIn("touch-action:pan-x", app.CSS)
        self.assertIn("class=\"details-html\"", app.DETAILS_HTML)

    def test_player_preloader_and_cache_hide_button(self):
        html = self.client.get('/watch/Example.2026.mp4').data.decode()
        self.assertIn('id="playerPreloader"', html)
        self.assertIn('class="player-preloader"', html)
        self.assertIn('class="player-preloader-spinner"', html)
        self.assertIn('Loading Media', html)
        self.assertIn('id="playerPreloaderMsg"', html)
        self.assertIn('id="cacheHideBtn"', html)
        self.assertIn('class="cache-hide-btn"', html)
        self.assertIn('Hide', html)
        self.assertIn('.player-preloader', app.CSS)
        self.assertIn('.cache-hide-btn', app.CSS)
        self.assertIn('hidePreloader()', html)
        self.assertIn('cacheDismissed', html)

    def test_vendor_hls_script_and_transcoder_proxy(self):
        # Verify local vendor hls asset is served
        res = self.client.get('/static/vendor/hls.min.js')
        self.assertEqual(res.status_code, 200)
        self.assertIn(b'Hls', res.data)

        # Test ProcessProxy
        proxy = app.ProcessProxy(os.getpid())
        self.assertIsNone(proxy.poll()) # Current process is alive

        dead_proxy = app.ProcessProxy(99999999)
        self.assertEqual(dead_proxy.poll(), 0) # Non-existent process is reported dead

    def test_hls_transcode_resume_and_completeness(self):
        # 1. Test _is_hls_truly_complete
        pl_file = Path(TMP.name) / 'test_pl.m3u8'
        media_file = Path(TMP.name) / 'test_vid.mkv'
        media_file.write_bytes(b'dummy')

        self.assertFalse(app._is_hls_truly_complete(pl_file, media_file))

        # Playlist with ENDLIST but only 20s out of 100s source
        pl_file.write_text("#EXTM3U\n#EXTINF:10.0,\nseg0.ts\n#EXTINF:10.0,\nseg1.ts\n#EXT-X-ENDLIST\n")
        with patch('app.probe_media', return_value={'format': {'duration': '100.0'}}):
            self.assertFalse(app._is_hls_truly_complete(pl_file, media_file))

        # Playlist covering 95% of source
        pl_file.write_text("#EXTM3U\n#EXTINF:50.0,\nseg0.ts\n#EXTINF:45.0,\nseg1.ts\n#EXT-X-ENDLIST\n")
        with patch('app.probe_media', return_value={'format': {'duration': '100.0'}}):
            self.assertTrue(app._is_hls_truly_complete(pl_file, media_file))

        # 2. Test _hls_resume_point
        test_hls_dir = Path(TMP.name) / 'hls_test'
        test_hls_dir.mkdir(parents=True, exist_ok=True)
        test_pl = test_hls_dir / 'playlist.m3u8'

        # Non-existent playlist
        t, count = app._hls_resume_point(test_hls_dir, test_pl)
        self.assertEqual(t, 0.0)
        self.assertEqual(count, 0)

        # Playlist with 2 valid segments on disk
        (test_hls_dir / 'seg0.ts').write_bytes(b'data')
        (test_hls_dir / 'seg1.ts').write_bytes(b'data')
        test_pl.write_text("#EXTM3U\n#EXTINF:4.000000,\nseg0.ts\n#EXTINF:4.000000,\nseg1.ts\n")

        t, count = app._hls_resume_point(test_hls_dir, test_pl)
        self.assertEqual(t, 8.0)
        self.assertEqual(count, 2)

        # Truncated trailing segment (file missing)
        test_pl.write_text("#EXTM3U\n#EXTINF:4.000000,\nseg0.ts\n#EXTINF:4.000000,\nseg1.ts\n#EXTINF:4.000000,\nseg2.ts\n")
        t, count = app._hls_resume_point(test_hls_dir, test_pl)
        self.assertEqual(t, 8.0)
        self.assertEqual(count, 2)
        # Playlist should be trimmed of the invalid trailing segment
        self.assertNotIn('seg2.ts', test_pl.read_text())

    def test_subtitle_vertical_position_and_nerd_stats(self):
        # Movie with subtitles
        html_sub = self.client.get('/watch/Example.2026.mp4').data.decode()
        self.assertEqual(html_sub.count('</script>'), 1)
        # Verify shell is closed cleanly before watch-info
        self.assertIn('</div><main class="watch-info">', html_sub)
        # Verify watch-back and watch-title-badge (no duplicated movie title)
        self.assertIn('<a class="watch-back"', html_sub)
        self.assertIn('← Details</a>', html_sub)
        self.assertIn('class="watch-title-badge"', html_sub)
        # Verify Subtitle Vertical Position select with Lowered Bottom as default
        self.assertIn('id="subVerticalSelect"', html_sub)
        self.assertIn('<option value="lowered" selected>Lowered Bottom (Default)</option>', html_sub)
        self.assertIn('value="bottom"', html_sub)
        self.assertIn('value="raised"', html_sub)
        self.assertIn('value="middle"', html_sub)
        self.assertIn('value="top"', html_sub)
        self.assertIn('id="subPosSelect"', html_sub)
        self.assertIn("verticalPos:'lowered'", html_sub)
        # Verify English track default selection
        self.assertIn('findEnglishTrack', html_sub)
        self.assertIn('selected>English', html_sub)
        # Verify Stats for Nerds button & HUD
        self.assertIn('id="nerdStatsBtn"', html_sub)
        self.assertIn('id="nerdStatsHud"', html_sub)
        self.assertIn('id="closeNerdStats"', html_sub)
        self.assertIn('id="nsFrames"', html_sub)
        self.assertIn('id="nsBuffer"', html_sub)
        self.assertIn('id="nsRes"', html_sub)
        # Verify controls-row invariants
        controls_row = html_sub.split('<div class="controls-row">')[1].split('</div>')[0]
        self.assertTrue(controls_row.startswith('<button id="restartBtn"'))
        self.assertNotIn('<div', controls_row)
        self.assertIn('id="nerdStatsBtn"', controls_row)
        # Verify shortcut key handling
        self.assertIn("e.key==='n'||e.key==='N'", html_sub)

    def test_api_upload_endpoint_valid_video(self):
        import io
        data = {
            'file': (io.BytesIO(b'dummy-video-data-12345'), 'Upload_Test_Movie.2025.mp4')
        }
        res = self.client.post('/api/upload', data=data, content_type='multipart/form-data')
        self.assertEqual(res.status_code, 200)
        json_data = res.get_json()
        self.assertTrue(json_data['success'])
        self.assertIn('Upload_Test_Movie', json_data['filename'])
        self.assertIn('Upload Test Movie', json_data['title'])
        self.assertEqual(json_data['year'], 2025)
        self.assertIn('/movie/', json_data['details_url'])
        # Verify file exists on disk in MEDIA_ROOT
        saved_file = Path(app.config.MEDIA_ROOT) / json_data['filename']
        self.assertTrue(saved_file.is_file())
        self.assertEqual(saved_file.read_bytes(), b'dummy-video-data-12345')

    def test_api_upload_endpoint_rejects_invalid_extension(self):
        import io
        data = {
            'file': (io.BytesIO(b'malicious content'), 'malicious_script.sh')
        }
        res = self.client.post('/api/upload', data=data, content_type='multipart/form-data')
        self.assertEqual(res.status_code, 400)
        self.assertIn('Unsupported video format', res.get_json()['error'])

    def test_api_upload_endpoint_missing_file(self):
        res = self.client.post('/api/upload', data={}, content_type='multipart/form-data')
        self.assertEqual(res.status_code, 400)
        self.assertIn('No file uploaded', res.get_json()['error'])

    def test_homepage_renders_upload_button_and_modal(self):
        res = self.client.get('/')
        self.assertEqual(res.status_code, 200)
        html = res.data.decode('utf-8')
        self.assertIn('id="uploadBtn"', html)
        self.assertIn('openUploadModal()', html)
        self.assertIn('id="uploadModal"', html)
        self.assertIn('id="uploadDropZone"', html)
        self.assertIn('id="mediaFileInput"', html)
        self.assertIn('id="uploadTitleInput"', html)
        self.assertIn('id="uploadTitleWrap"', html)
        self.assertIn('id="uploadProgressBar"', html)
        self.assertIn('id="uploadSubmitBtn"', html)

    def test_api_upload_with_custom_title_override(self):
        import io
        from unittest.mock import patch
        data = {
            'file': (io.BytesIO(b'dummy-mkv-video-content'), '1000403712.mkv'),
            'title': 'Mayday (2026)'
        }
        mock_details = {'title': 'Mayday', 'release_date': '2026-05-01', 'id': 1137844}
        with patch('scanner.scan_single_file', return_value=mock_details):
            res = self.client.post('/api/upload', data=data, content_type='multipart/form-data')
            self.assertEqual(res.status_code, 200)
            json_data = res.get_json()
            self.assertTrue(json_data['success'])
            self.assertIn('Mayday (2026).mkv', json_data['filename'])
            self.assertEqual(json_data['title'], 'Mayday')
            self.assertEqual(json_data['year'], 2026)
            saved_file = Path(app.config.MEDIA_ROOT) / json_data['filename']
            self.assertTrue(saved_file.is_file())
            self.assertEqual(saved_file.read_bytes(), b'dummy-mkv-video-content')

    def test_player_page_renders_header_branding_and_nav_links(self):
        res = self.client.get('/watch/Example.2026.mp4')
        self.assertEqual(res.status_code, 200)
        html = res.data.decode('utf-8')
        self.assertIn('class="player-header"', html)
        self.assertIn("Anis'", html)
        self.assertIn('Media Library', html)
        self.assertIn('class="player-header-actions"', html)
        self.assertIn('Home', html)
        self.assertIn('Details', html)
        self.assertIn('My Library', html)

    def test_player_and_details_pages_render_transcode_progress_elements(self):
        # When no transcode is active, elements exist but are hidden (display:none)
        watch_html = self.client.get('/watch/Example.2026.mp4').data.decode('utf-8')
        self.assertIn('id="playerTranscodeCard"', watch_html)
        self.assertIn('id="shellTranscodePill"', watch_html)
        self.assertIn('pollTranscodeMonitor()', watch_html)

        details_html = self.client.get('/movie/Example.2026.mp4').data.decode('utf-8')
        self.assertIn('id="detailsTranscodeCard"', details_html)
        self.assertIn('pollDetailsTranscode()', details_html)

    def test_player_and_details_render_live_transcode_values_when_active(self):
        mock_active = [{
            'filename': 'Example.2026.mp4',
            'title': 'Example',
            'percent': 42.5,
            'speed_str': '2.4x',
            'encoded_str': '0:42',
            'duration_str': '1:40',
            'eta_str': '1m 15s',
            'mode': 'HLS'
        }]
        with patch('app.routes.pages.get_active_transcodes', return_value=mock_active):
            watch_html = self.client.get('/watch/Example.2026.mp4').data.decode('utf-8')
            self.assertIn('42.5%', watch_html)
            self.assertIn('2.4x', watch_html)
            self.assertIn('1m 15s', watch_html)

            details_html = self.client.get('/movie/Example.2026.mp4').data.decode('utf-8')
            self.assertIn('42.5%', details_html)
            self.assertIn('2.4x', details_html)
            self.assertIn('1m 15s', details_html)

    def test_player_merged_subtitle_button_and_controls_invariants(self):
        mkv = Path(TMP.name) / 'MergedCC.2026.mkv'
        mkv.write_bytes(b'dummy-content')
        (Path(TMP.name) / 'MergedCC.2026.en.srt').write_text("1\n00:00:00,000 --> 00:00:01,000\nHello\n")
        res = self.client.get('/watch/MergedCC.2026.mkv')
        self.assertEqual(res.status_code, 200)
        html = res.data.decode('utf-8')

        # Verify merged pill exists
        self.assertIn('class="cc-merged-pill"', html)
        self.assertIn('id="ccMergedPill"', html)
        self.assertIn('class="cc-sep"', html)
        self.assertIn('id="ccBtn"', html)
        self.assertIn('id="subSettingsBtn"', html)

        # Verify controls-row invariant: no nested <div>, starts with restartBtn
        controls_row = html.split('<div class="controls-row">')[1].split('</div>')[0]
        self.assertTrue(controls_row.startswith('<button id="restartBtn"'))
        self.assertNotIn('<div', controls_row)
        self.assertIn('id="ccMergedPill"', controls_row)

        # Verify JS long-press & click handling
        self.assertIn('ccHoldTimer', html)
        self.assertIn('ccHoldFired', html)
        self.assertIn('cancelCcHold', html)

    def test_player_modals_fixed_viewport_and_dismissal(self):
        mkv = Path(TMP.name) / 'ModalFix.2026.mkv'
        mkv.write_bytes(b'dummy-content')
        (Path(TMP.name) / 'ModalFix.2026.en.srt').write_text("1\n00:00:00,000 --> 00:00:01,000\nHello\n")
        res = self.client.get('/watch/ModalFix.2026.mkv')
        self.assertEqual(res.status_code, 200)
        html = res.data.decode('utf-8')

        # Verify CSS rules for fixed viewport and backdrop shadow
        self.assertIn('.sub-modal{position:fixed;z-index:100;left:50%;top:50%;transform:translate(-50%,-50%)', html)
        self.assertIn('box-shadow:0 0 0 100vmax rgba(0,0,0,.7)', html)
        self.assertIn('@media(max-width:768px){', html)
        self.assertIn('.nerd-stats-hud{position:fixed;z-index:100;top:50%;left:50%;transform:translate(-50%,-50%)', html)

        # Verify document click dismissal and Escape dismissal
        self.assertIn("document.addEventListener('click',e=>{if(typeof subSettingsModal!=='undefined'", html)
        self.assertIn("if(e.key==='Escape')", html)

    def test_mobile_player_height_and_controls_row_responsiveness(self):
        mkv = Path(TMP.name) / 'MobilePlayerTest.2026.mkv'
        mkv.write_bytes(b'dummy-content')
        vtt = Path(TMP.name) / 'MobilePlayerTest.2026.en.vtt'
        vtt.write_text("WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nHello world\n")
        res = self.client.get('/watch/MobilePlayerTest.2026.mkv')
        self.assertEqual(res.status_code, 200)
        html = res.data.decode('utf-8')

        # Verify increased playback screen height in non-fullscreen mobile mode
        self.assertIn('@media(max-width:768px) and (min-height:501px){#shell{width:100%;aspect-ratio:auto;height:min(52vh,460px);min-height:330px;max-height:60vh}}', html)

        # Verify mobile controls rules: volume, shortcuts cheat-sheet, and +/-10s seek buttons are hidden on mobile
        self.assertIn('#volume,#shortcutsBtn,#skipBackBtn,#skipForwardBtn{display:none!important}', html)
        self.assertIn('#controls #restartBtn', html)
        self.assertIn('#controls #mute', html)
        self.assertIn('overflow-x: auto !important', html)

        # Verify responsive unified player-header on mobile
        self.assertIn('.player-header{flex-direction:column;align-items:stretch;gap:.6rem', html)

        # Verify elevated mobile subtitle cues
        self.assertIn('isMob?(isHuge?-5.8:-5.0):(isHuge?-4.8:-4)', html)

        # Verify polished seek-ripple pill styling
        self.assertIn('.seek-ripple{display:none;position:absolute;top:50%;transform:translateY(-50%)', html)
        self.assertIn('background:rgba(18,22,32,.82)', html)



