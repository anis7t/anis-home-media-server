import { describe, expect, it } from 'vitest';
import { probeClientMediaCapabilities } from './mediaCapabilities';

describe('probeClientMediaCapabilities', () => {
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
});
