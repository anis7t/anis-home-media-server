"""Subtitle conversion and hashing utilities."""
import re
import struct
from pathlib import Path


def compute_opensubtitles_hash(path):
    """Compute 64-bit OpenSubtitles hash for a media file."""
    longlongformat = '<q'
    bytesize = struct.calcsize(longlongformat)
    path = Path(path)
    try:
        filesize = path.stat().st_size
    except OSError:
        return None, 0
    if filesize < 65536 * 2:
        return None, filesize
    hash_val = filesize
    with open(path, "rb") as f:
        for _ in range(65536 // bytesize):
            buf = f.read(bytesize)
            (val,) = struct.unpack(longlongformat, buf)
            hash_val = (hash_val + val) & 0xFFFFFFFFFFFFFFFF
        f.seek(max(0, filesize - 65536), 0)
        for _ in range(65536 // bytesize):
            buf = f.read(bytesize)
            (val,) = struct.unpack(longlongformat, buf)
            hash_val = (hash_val + val) & 0xFFFFFFFFFFFFFFFF
    return f"{hash_val:016x}", filesize


def srt_to_vtt(text):
    """Convert SRT formatted subtitle text to WebVTT format."""
    lines = text.replace('\r\n', '\n').replace('\r', '\n').split('\n')
    out = ["WEBVTT\n"]
    time_pat = re.compile(r'((?:\d\d:)?\d\d:\d\d,\d{3}\s*-->\s*(?:\d\d:)?\d\d:\d\d,\d{3})')
    for line in lines:
        if line.strip().isdigit() and (not out or out[-1] == ''):
            continue
        if '-->' in line:
            m = time_pat.search(line)
            if m:
                out.append(line.replace(',', '.'))
            else:
                out.append(line)
        else:
            out.append(line)
    return '\n'.join(out)


def detect_subtitle_language(source):
    """Detect ISO 639-1 language code from a subtitle file path or text content."""
    if isinstance(source, (str, Path)) and (isinstance(source, Path) or '\n' not in source):
        path = Path(source)
        if path.is_file():
            try:
                text = path.read_text(encoding='utf-8', errors='replace')
            except Exception:
                return 'und'
        else:
            text = str(source)
    else:
        text = str(source)

    if not text:
        return 'und'

    lines = [
        l.strip() for l in text.splitlines()
        if l.strip() and not l.strip().isdigit() and '-->' not in l and not l.startswith('WEBVTT')
    ]
    sample = ' '.join(lines[:100]).lower()
    if not sample:
        return 'und'

    # Non-Latin script checks
    if any('\u0900' <= ch <= '\u097f' for ch in sample):
        return 'hi'  # Hindi (Devanagari)
    if any('\u0400' <= ch <= '\u04ff' for ch in sample):
        return 'ru'  # Russian (Cyrillic)
    if any('\u4e00' <= ch <= '\u9fff' for ch in sample):
        return 'zh'  # Chinese
    if any('\u3040' <= ch <= '\u30ff' for ch in sample):
        return 'ja'  # Japanese (Hiragana/Katakana)
    if any('\uac00' <= ch <= '\ud7af' for ch in sample):
        return 'ko'  # Korean (Hangul)
    if any('\u0600' <= ch <= '\u06ff' for ch in sample):
        return 'ar'  # Arabic
    if any('\u0980' <= ch <= '\u09ff' for ch in sample):
        return 'bn'  # Bengali

    words = set(re.findall(r'\b[a-z]{2,}\b', sample))
    if not words:
        return 'und'

    word_lists = {
        'en': {'the', 'and', 'to', 'of', 'in', 'is', 'it', 'you', 'that', 'he', 'was', 'for', 'on', 'are', 'with', 'as', 'his', 'they', 'at', 'have', 'this', 'from', 'or', 'had', 'by', 'not', 'but', 'what', 'some', 'we', 'can', 'out', 'other', 'were', 'all', 'there', 'when', 'up', 'your', 'how', 'said', 'an', 'each', 'she'},
        'es': {'que', 'de', 'no', 'la', 'el', 'es', 'en', 'lo', 'un', 'por', 'me', 'una', 'te', 'los', 'se', 'con', 'para', 'mi', 'está', 'si', 'bien', 'pero', 'yo', 'eso', 'las', 'más'},
        'fr': {'de', 'je', 'est', 'pas', 'que', 'le', 'la', 'tu', 'un', 'il', 'et', 'ce', 'en', 'on', 'une', 'les', 'pour', 'des', 'dans', 'moi', 'qui', 'nous', 'elle', 'mais', 'du'},
        'de': {'das', 'ist', 'du', 'nicht', 'die', 'es', 'und', 'sie', 'der', 'was', 'wir', 'zu', 'ein', 'ich', 'in', 'dem', 'mit', 'den', 'so', 'eine', 'auf', 'mich', 'dass'},
        'it': {'che', 'non', 'di', 'la', 'il', 'un', 'sono', 'per', 'una', 'in', 'mi', 'ho', 'ma', 'ha', 'si', 'lo', 'ti', 'le', 'cosa', 'con', 'ci', 'io', 'questo', 'bene'},
        'pt': {'que', 'não', 'de', 'um', 'para', 'uma', 'com', 'ele', 'em', 'os', 'no', 'se', 'na', 'por', 'mais', 'as', 'dos', 'como', 'mas', 'foi', 'ao', 'ele', 'das'},
    }

    scores = {lang: len(words.intersection(vocab)) for lang, vocab in word_lists.items()}
    best_lang, best_score = max(scores.items(), key=lambda item: item[1])
    if best_score >= 3:
        return best_lang
    if scores['en'] >= 1:
        return 'en'
    return 'und'


def get_short_movie_name(path):
    """Derive clean, normalized short movie name identifier (e.g. 'moana', 'the_odyssey')."""
    p = Path(path)
    stem = p.stem
    try:
        import scanner
        parsed_title, _ = scanner.parse_filename(p)
        if parsed_title:
            stem = parsed_title
    except Exception:
        pass
    clean = re.sub(r'[^a-zA-Z0-9]+', '_', stem).strip('_').lower()
    return clean or 'video'


