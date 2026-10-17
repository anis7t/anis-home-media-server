import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import {
  clearVerdictCache,
  normalizeVideoCodecMime,
  probeClientMediaCapabilities,
} from './mediaCapabilities';

describe('normalizeVideoCodecMime', () => {
  it('generates Level 5.0 MIME for 4K HEVC and Level 4.0 for 1080p HEVC', () => {
    const mime4k = normalizeVideoCodecMime('mp4', 'hevc', 3840, 2160);
    expect(mime4k).toBe('video/mp4; codecs="hvc1.1.6.L150.90"');

    const mime1080p = normalizeVideoCodecMime('mp4', 'hevc', 1920, 1080);
    expect(mime1080p).toBe('video/mp4; codecs="hvc1.1.6.L120.90"');
  });

  it('generates Level 5.1 MIME for 4K H.264', () => {
    const mime4k = normalizeVideoCodecMime('mp4', 'h264', 3840, 2160);
    expect(mime4k).toBe('video/mp4; codecs="avc1.640033"');
  });
});

describe('probeClientMediaCapabilities', () => {
  beforeEach(() => {
    clearVerdictCache();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('identifies MP4 with H.264 and AAC as direct-playable', async () => {
    const verdict = await probeClientMediaCapabilities('mp4', 'h264', 'aac');
    expect(verdict.canDirectPlay).toBe(true);
    expect(verdict.reason).toBeUndefined();
  });

  it('rejects MKV on web browsers that lack native Matroska demuxing', async () => {
    const verdict = await probeClientMediaCapabilities('mkv', 'hevc', 'eac3');
    expect(verdict.canDirectPlay).toBe(false);
    expect(verdict.reason).toContain('Matroska');
  });

  it('rejects MP4 with unsupported Dolby Digital Plus (E-AC-3) when canPlayType returns empty', async () => {
    const verdict = await probeClientMediaCapabilities('mp4', 'h264', 'eac3');
    expect(verdict.canDirectPlay).toBe(false);
    expect(verdict.reason).toContain('Dolby Digital Plus');
  });

  it('accepts WebM with VP9 and Opus', async () => {
    const verdict = await probeClientMediaCapabilities('webm', 'vp9', 'opus');
    expect(verdict.canDirectPlay).toBe(true);
  });

  it('unlocks 4K HEVC Direct Play when W3C mediaCapabilities reports supported', async () => {
    const decodingInfoMock = vi.fn().mockImplementation(async (config: any) => {
      if (
        config.video.contentType.includes('hvc1.1.6.L150.90') &&
        config.video.width === 3840
      ) {
        return { supported: true, smooth: true, powerEfficient: true };
      }
      return { supported: false, smooth: false, powerEfficient: false };
    });

    Object.defineProperty(navigator, 'mediaCapabilities', {
      value: { decodingInfo: decodingInfoMock },
      configurable: true,
      writable: true,
    });

    const verdict = await probeClientMediaCapabilities('mp4', 'hevc', 'aac', {
      width: 3840,
      height: 2160,
    });

    expect(verdict.canDirectPlay).toBe(true);
    expect(verdict.smooth).toBe(true);
    expect(verdict.powerEfficient).toBe(true);
    expect(decodingInfoMock).toHaveBeenCalled();
  });

  it('probes alternate hev1 tag if hvc1 tag is rejected', async () => {
    const decodingInfoMock = vi.fn().mockImplementation(async (config: any) => {
      if (config.video.contentType.includes('hev1.1.6.L150.90')) {
        return { supported: true, smooth: true, powerEfficient: true };
      }
      return { supported: false, smooth: false, powerEfficient: false };
    });

    Object.defineProperty(navigator, 'mediaCapabilities', {
      value: { decodingInfo: decodingInfoMock },
      configurable: true,
      writable: true,
    });

    const verdict = await probeClientMediaCapabilities('mp4', 'hevc', 'aac', {
      width: 3840,
      height: 2160,
      bitrate: 20_000_000,
    });

    expect(verdict.canDirectPlay).toBe(true);
    expect(decodingInfoMock).toHaveBeenCalledTimes(2);
  });
});
