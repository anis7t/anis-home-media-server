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

