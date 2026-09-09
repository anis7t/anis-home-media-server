import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

TMP = tempfile.TemporaryDirectory()
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
        app.CACHE_DIR = Path(TMP.name) / 'cache'
        app.cleanup_cache()
        self.assertTrue(final.exists())
        self.assertTrue(valid_part.exists())
        self.assertFalse(stale_part.exists())
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
        with patch.dict(os.environ, {}, clear=True):
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
        self.assertIn('video::cue', html)
        self.assertIn('toggleCC()', html)
        self.assertIn('applySubStyles()', html)
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
