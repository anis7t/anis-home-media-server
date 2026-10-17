/**
 * Playback URL construction.
 *
 * Gate F: these mirror the server's routes exactly and change nothing about
 * them.
 *   - `app/routes/media.py:232` -> `/media/<path:filename>`  (RFC 7233 byte range)
 *   - `app/routes/media.py:336` -> `/hls/<path:filename>/playlist.m3u8`
 *
 * `/media/` and `/hls/` are the two paths `CORS_PATHS` already covers, so a
 * Cast receiver - or any other cross-origin runtime - can read them unchanged.
 * `/api/*` is deliberately outside that scope and this module never adds a
 * header to it.
 */
import { encodePathSegments } from './client';

export const DIRECT_MEDIA_PATH = '/media/';
export const HLS_PLAYLIST_SUFFIX = '/playlist.m3u8';

/** Byte-range URL for direct play (MP4/M4V/WebM). */
export function directMediaUrl(filename: string): string {
  return `${DIRECT_MEDIA_PATH}${encodePathSegments(filename)}`;
}

/** Master playlist or tiered quality URL for transcoded playback. */
export function hlsPlaylistUrl(filename: string, quality?: string): string {
  const enc = encodePathSegments(filename);
  if (!quality || quality === 'default') {
    return `/hls/${enc}${HLS_PLAYLIST_SUFFIX}`;
  }
  if (quality === 'auto') {
    return `/hls/${enc}/master.m3u8`;
  }
  return `/hls/${enc}/${quality}${HLS_PLAYLIST_SUFFIX}`;
}

export type PlaybackMode = 'direct' | 'hls';

/**
 * Choose the playback mode from the server's authoritative `direct_play` flag.
 *
 * This is deliberately not inferred from the file extension. The extension
 * says what a *container* is; only the probe says whether this particular
 * stream can be handed to a browser as bytes. `AGENTS.md` is explicit that
 * `/api/media-info`'s `direct_play` is the authoritative flag consumed by both
 * the Flutter and web players.
 */
export function playbackModeFor(directPlay: boolean): PlaybackMode {
  return directPlay ? 'direct' : 'hls';
}

export function playbackUrlFor(filename: string, mode: PlaybackMode, quality?: string): string {
  return mode === 'direct' ? directMediaUrl(filename) : hlsPlaylistUrl(filename, quality);
}