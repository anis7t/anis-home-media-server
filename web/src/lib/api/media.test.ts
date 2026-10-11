import { describe, expect, it } from 'vitest';
import {
  directMediaUrl,
  hlsPlaylistUrl,
  playbackModeFor,
  playbackUrlFor,
} from './media';
import { encodePathSegments } from './client';

const NESTED = '2001 A Space Odyssey (1968) [BluRay]/2001.A.Space.Odyssey.1968.1080p.mkv';

describe('encodePathSegments', () => {
  it('preserves separators so <path:filename> routes still resolve', () => {
    // Encoding the whole string would turn the path into one segment.
    expect(encodePathSegments(NESTED)).toBe(
      '2001%20A%20Space%20Odyssey%20(1968)%20%5BBluRay%5D/2001.A.Space.Odyssey.1968.1080p.mkv',
    );
  });
});

describe('playback urls', () => {
  it('builds the byte-range url for direct play', () => {
    expect(directMediaUrl(NESTED)).toBe(`/media/${encodePathSegments(NESTED)}`);
  });

  it('builds the master playlist url for HLS', () => {
    expect(hlsPlaylistUrl(NESTED)).toBe(`/hls/${encodePathSegments(NESTED)}/playlist.m3u8`);
  });

  it('maps the authoritative direct_play flag to a mode', () => {
    // The extension is deliberately ignored: only the probe knows.
    expect(playbackModeFor(true)).toBe('direct');
    expect(playbackModeFor(false)).toBe('hls');
  });

  it('selects the matching url for each mode', () => {
    expect(playbackUrlFor('a.mkv', 'direct')).toBe('/media/a.mkv');
    expect(playbackUrlFor('a.mkv', 'hls')).toBe('/hls/a.mkv/playlist.m3u8');
  });
});