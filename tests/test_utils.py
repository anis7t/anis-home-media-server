"""Unit tests for utility functions."""
import unittest
from pathlib import Path
from app.utils.formatting import clean_title, format_bytes_display, format_eta, format_runtime_display
from app.utils.filesystem import is_video, mimetype, parse_range
from app.utils.subtitles import compute_opensubtitles_hash, detect_subtitle_language, srt_to_vtt


class UtilsTests(unittest.TestCase):
    def test_clean_title(self):
        self.assertEqual(clean_title("Satluj.2026.1080p.HEVC.x265.mkv"), "Satluj 2026")
        self.assertEqual(clean_title("The_Matrix_1999_4k_bluray.mp4"), "The Matrix 1999")

    def test_format_runtime(self):
        self.assertEqual(format_runtime_display(125), "2 hr 5 min")
        self.assertEqual(format_runtime_display(60), "1 hr")
        self.assertEqual(format_runtime_display(45), "45 min")
        self.assertEqual(format_runtime_display(0), "")

    def test_format_bytes(self):
        self.assertEqual(format_bytes_display(500), "500 B")
        self.assertEqual(format_bytes_display(1024 * 512), "512 KB")
        self.assertIn("MB", format_bytes_display(15 * 1024 * 1024))
        self.assertIn("GB", format_bytes_display(2 * 1024 * 1024 * 1024))

    def test_format_eta(self):
        self.assertEqual(format_eta(45), "45s")
        self.assertEqual(format_eta(125), "2m 5s")
        self.assertEqual(format_eta(3665), "1h 1m")

    def test_srt_to_vtt(self):
        srt = "1\n00:00:01,000 --> 00:00:04,000\nSubtitle text\n"
        vtt = srt_to_vtt(srt)
        self.assertTrue(vtt.startswith("WEBVTT\n\n"))
        self.assertIn("00:00:01.000 --> 00:00:04.000", vtt)

    def test_parse_range(self):
        self.assertEqual(parse_range("bytes=0-99", 200), (0, 99))
        self.assertEqual(parse_range("bytes=50-", 200), (50, 199))
        self.assertEqual(parse_range("bytes=-50", 200), (150, 199))
        self.assertEqual(parse_range("bytes=250-300", 200), 'bad')
        self.assertIsNone(parse_range(None, 200))

    def test_detect_subtitle_language(self):
        en_text = "1\n00:00:01,000 --> 00:00:03,000\nThis is a test of the English language subtitle detector.\n"
        self.assertEqual(detect_subtitle_language(en_text), 'en')

        es_text = "1\n00:00:01,000 --> 00:00:03,000\nQue no te preocupes por eso que está bien y es para ti.\n"
        self.assertEqual(detect_subtitle_language(es_text), 'es')

        hi_text = "1\n00:00:01,000 --> 00:00:03,000\nनमस्ते दुनिया यह एक परीक्षण है\n"
        self.assertEqual(detect_subtitle_language(hi_text), 'hi')

        empty_text = "1\n00:00:01,000 --> 00:00:03,000\n12345\n"
        self.assertEqual(detect_subtitle_language(empty_text), 'und')

