import os
import tempfile
import unittest
from pathlib import Path

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
