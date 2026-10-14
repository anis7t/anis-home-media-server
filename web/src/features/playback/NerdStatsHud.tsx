import { useEffect, useState } from 'react';

export interface NerdStatsHudProps {
  isOpen: boolean;
  onClose: () => void;
  videoRef: React.RefObject<HTMLVideoElement | null>;
  filename: string;
  mode?: 'direct' | 'hls';
  directPlay?: boolean;
  isTranscodeReady?: boolean;
  transcodePercent?: number;
}

interface StatsState {
  file: string;
  res: string;
  viewport: string;
  codecs: string;
  frames: string;
  buffer: string;
  transcode: string;
  rate: string;
}

export function NerdStatsHud({
  isOpen,
  onClose,
  videoRef,
  filename,
  mode,
  directPlay = false,
  isTranscodeReady = false,
  transcodePercent,
}: NerdStatsHudProps) {
  const [stats, setStats] = useState<StatsState>({
    file: '-',
    res: '-',
    viewport: '-',
    codecs: '-',
    frames: '0 / 0 (0.0%)',
    buffer: '0.0 s',
    transcode: '-',
    rate: '1.0× · Vol: 100% · Paused',
  });

  useEffect(() => {
    if (!isOpen) return;

    const updateStats = () => {
      const v = videoRef.current;
      const baseName = filename.split('/').pop() || filename;

      // Codecs
      let codecs = 'Direct Stream (Native)';
      if (mode === 'hls') {
        codecs = 'HLS.js (fMP4 / AAC)';
      } else if (!directPlay) {
        codecs = 'Transcoded MP4';
      }

      // Live transcode status
      let transcode = 'Direct Stream (Native)';
      if (!directPlay) {
        if (isTranscodeReady) {
          transcode = 'Ready (100% cached)';
        } else if (transcodePercent != null) {
          transcode = `Transcoding · ${Math.round(transcodePercent)}%`;
        } else {
          transcode = 'Active';
        }
      }

      if (!v) {
        setStats((prev) => ({ ...prev, file: baseName, codecs, transcode }));
        return;
      }
      const w = v.videoWidth || 0;
      const h = v.videoHeight || 0;
      const lbl = w >= 1920 ? '1080p' : w >= 1280 ? '720p' : w > 0 ? 'SD' : '';
      const res = w && h ? `${w}×${h}${lbl ? ` (${lbl})` : ''}` : 'Loading...';

      // Viewport
      const viewport = `${v.clientWidth}×${v.clientHeight}`;

      // Dropped frames via getVideoPlaybackQuality
      let frames = 'N/A';
      const q = typeof v.getVideoPlaybackQuality === 'function' ? v.getVideoPlaybackQuality() : null;
      if (q && q.totalVideoFrames > 0) {
        const dPct = ((q.droppedVideoFrames / q.totalVideoFrames) * 100).toFixed(1);
        frames = `${q.droppedVideoFrames} / ${q.totalVideoFrames} (${dPct}%)`;
      } else if (q) {
        frames = '0 / 0 (0.0%)';
      }

      // Buffer health (forward buffer from current position)
      let fwd = 0;
      if (v.buffered && v.buffered.length > 0) {
        for (let i = 0; i < v.buffered.length; i++) {
          if (v.buffered.start(i) <= v.currentTime + 1 && v.buffered.end(i) >= v.currentTime) {
            fwd = Math.max(fwd, v.buffered.end(i) - v.currentTime);
          }
        }
      }
      const buffer = `${fwd.toFixed(1)} s`;

      // Playback state
      const vol = Math.round((v.muted ? 0 : v.volume) * 100);
      const st = v.paused ? 'Paused' : 'Playing';
      const rate = `${(v.playbackRate || 1.0).toFixed(2).replace(/\.?0+$/, '')}× · Vol: ${vol}% · ${st}`;

      setStats({
        file: baseName,
        res,
        viewport,
        codecs,
        frames,
        buffer,
        transcode,
        rate,
      });
    };

    updateStats();
    const timer = setInterval(updateStats, 400);

    return () => clearInterval(timer);
  }, [isOpen, videoRef, filename, mode, directPlay, isTranscodeReady, transcodePercent]);

  if (!isOpen) return null;

  return (
    <div
      id="nerdStatsHud"
      className="nerd-stats-hud"
      onClick={(e) => e.stopPropagation()}
      data-testid="nerd-stats-hud"
    >
      <div className="nerd-stats-header">
        <div className="nerd-stats-title-wrap">
          <svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor">
            <path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zM9 17H7v-5h2v5zm4 0h-2v-9h2v9zm4 0h-2v-4h2v4z" />
          </svg>
          <span>Stats for nerds</span>
        </div>
        <button
          id="closeNerdStats"
          type="button"
          onClick={onClose}
          className="nerd-stats-close"
          aria-label="Close stats"
        >
          &times;
        </button>
      </div>

      <div className="nerd-stats-body">
        <div className="nerd-row">
          <span>Video / File</span>
          <span id="nsFile" className="ns-val">
            {stats.file}
          </span>
        </div>
        <div className="nerd-row">
          <span>Resolution</span>
          <span id="nsRes" className="ns-val">
            {stats.res}
          </span>
        </div>
        <div className="nerd-row">
          <span>Viewport</span>
          <span id="nsViewport" className="ns-val">
            {stats.viewport}
          </span>
        </div>
        <div className="nerd-row">
          <span>Codecs / Stream</span>
          <span id="nsCodecs" className="ns-val">
            {stats.codecs}
          </span>
        </div>
        <div className="nerd-row">
          <span>Dropped Frames</span>
          <span id="nsFrames" className="ns-val">
            {stats.frames}
          </span>
        </div>
        <div className="nerd-row">
          <span>Buffer Health</span>
          <span id="nsBuffer" className="ns-val">
            {stats.buffer}
          </span>
        </div>
        <div className="nerd-row">
          <span>Live Transcode</span>
          <span id="nsTranscode" className="ns-val">
            {stats.transcode}
          </span>
        </div>
        <div className="nerd-row">
          <span>Playback State</span>
          <span id="nsRate" className="ns-val">
            {stats.rate}
          </span>
        </div>
      </div>
    </div>
  );
}
