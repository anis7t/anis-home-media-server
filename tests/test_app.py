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
    def test_hls_cache_route_is_generic_for_new_mkv_files(self):
        movie = Path(TMP.name) / 'New.Movie.2026.mkv'
        movie.write_bytes(b'new media')
        with patch('app.probe_media', return_value={'streams': [{'codec_type': 'video', 'codec_name': 'h264', 'width': 1920}]}), patch('app.subprocess.Popen'):
            response = self.client.get('/hls/New.Movie.2026.mkv/playlist.m3u8')
        self.assertEqual(response.status_code, 200)
        self.assertIn(b'#EXTM3U', response.data)
    def test_transcode_is_safe_when_ffmpeg_is_unavailable(self):
        with patch('app.which', return_value=None):
            response = self.client.get('/transcode/Example.2026.mp4')
        self.assertEqual(response.status_code, 503)
