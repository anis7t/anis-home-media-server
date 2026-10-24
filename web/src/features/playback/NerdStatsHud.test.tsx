import { render, screen, fireEvent } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { NerdStatsHud } from './NerdStatsHud';

describe('NerdStatsHud', () => {
  it('does not render when isOpen is false', () => {
    const videoRef = { current: null };
    render(
      <NerdStatsHud
        isOpen={false}
        onClose={vi.fn()}
        videoRef={videoRef}
        filename="Movies/Inception.mkv"
      />
    );

    expect(screen.queryByTestId('nerd-stats-hud')).toBeNull();
  });

  it('renders all telemetry fields and handles close', () => {
    const onClose = vi.fn();
    const fakeVideo = {
      videoWidth: 1920,
      videoHeight: 1080,
      clientWidth: 1280,
      clientHeight: 720,
      currentTime: 10,
      playbackRate: 1,
      volume: 0.8,
      muted: false,
      paused: false,
      buffered: {
        length: 1,
        start: () => 0,
        end: () => 30,
      },
      getVideoPlaybackQuality: () => ({
        totalVideoFrames: 1000,
        droppedVideoFrames: 2,
      }),
    } as unknown as HTMLVideoElement;

    const videoRef = { current: fakeVideo };

    render(
      <NerdStatsHud
        isOpen={true}
        onClose={onClose}
        videoRef={videoRef}
        filename="Action/The Matrix.mp4"
        mode="direct"
        directPlay={true}
      />
    );

    const hud = screen.getByTestId('nerd-stats-hud');
    expect(hud).toBeDefined();

    // Check DOM IDs
    expect(document.getElementById('nsFile')?.textContent).toBe('The Matrix.mp4');
    expect(document.getElementById('nsRes')?.textContent).toContain('1920×1080');
    expect(document.getElementById('nsViewport')?.textContent).toBe('1280×720');
    expect(document.getElementById('nsCodecs')?.textContent).toContain('Direct Stream');
    expect(document.getElementById('nsFrames')?.textContent).toContain('2 / 1000');
    expect(document.getElementById('nsBuffer')?.textContent).toContain('20.0 s');
    expect(document.getElementById('nsTranscode')?.textContent).toBe('Direct Stream (Native)');
    expect(document.getElementById('nsRate')?.textContent).toContain('1× · Vol: 80% · Playing');

    // Close button
    const closeBtn = document.getElementById('closeNerdStats');
    expect(closeBtn).toBeDefined();
    if (closeBtn) {
      fireEvent.click(closeBtn);
      expect(onClose).toHaveBeenCalledOnce();
    }
  });

  it('reports HLS codecs and transcode status when transcode is active', () => {
    const videoRef = { current: null };
    render(
      <NerdStatsHud
        isOpen={true}
        onClose={vi.fn()}
        videoRef={videoRef}
        filename="SciFi/Dune.mkv"
        mode="hls"
        directPlay={false}
        isTranscodeReady={false}
        transcodePercent={45.2}
      />
    );

    expect(document.getElementById('nsCodecs')?.textContent).toContain('HLS.js');
    expect(document.getElementById('nsTranscode')?.textContent).toBe('Transcoding · 45%');
  });
});
