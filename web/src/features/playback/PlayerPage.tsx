import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useParams } from 'react-router';
import { Icon } from '../../components/icons';
import {
  getMediaInfo,
  getProgress,
  getTranscodeStatus,
  setProgress,
} from '../../lib/api/client';
import { playbackModeFor, playbackUrlFor, type PlaybackMode } from '../../lib/api/media';
import { useDeviceId } from '../../lib/useDeviceId';
import type { MediaInfoResponse, TranscodeStatusResponse } from '../../lib/api/types';

/**
 * Minimum playback advance, in SECONDS, between persisted resume points.
 *
 * The unit is in the name on purpose. This constant was originally `_MS` and
 * was compared against `video.currentTime`, which is in seconds - so the
 * throttle demanded a 5000 *second* (83 minute) advance and watch progress was
 * silently never written during an ordinary viewing session. The unit tests
 * missed it because they stubbed `currentTime` and never ran this interval
 * against real media.
 */
const PROGRESS_INTERVAL_SECONDS = 5;

/**
 * Resume guards. Below `RESUME_MIN_SECONDS` the viewer has barely started and is
 * better off at zero; within `RESUME_TAIL_RATIO` of the end the title is
 * finished. Without these, a completed film reopens on its final frame, which
 * reads as a broken player rather than a watched one.
 */
const RESUME_MIN_SECONDS = 30;
const RESUME_TAIL_RATIO = 0.97;

function formatClock(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return '0:00';
  const total = Math.floor(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0
    ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
    : `${m}:${String(s).padStart(2, '0')}`;
}

export function PlayerPage() {
  // Splat route: the filename is a relative path and contains slashes.
  const params = useParams();
  const decoded = decodeURIComponent(params['*'] ?? '');
  const videoRef = useRef<HTMLVideoElement | null>(null);

  const [info, setInfo] = useState<MediaInfoResponse | undefined>();
  const [error, setError] = useState<Error | undefined>();
  const [loading, setLoading] = useState(true);
  const [transcode, setTranscode] = useState<TranscodeStatusResponse | undefined>();

  const [position, setPosition] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [duration, setDuration] = useState(0);
  const lastReportedRef = useRef(0);
  /** Mirrored position/duration, readable at teardown when the node is gone. */
  const lastPositionRef = useRef(0);
  const lastDurationRef = useRef(0);
  const resumePositionRef = useRef(0);
  const deviceId = useDeviceId();

  // --- Load the saved resume point ----------------------------------------
  useEffect(() => {
    const controller = new AbortController();
    let active = true;

    resumePositionRef.current = 0;

    getProgress(decoded, { signal: controller.signal, deviceId })
      .then((saved) => {
        if (active) resumePositionRef.current = saved.position ?? 0;
      })
      .catch(() => {
        // No saved progress, or the endpoint is unavailable: start at zero.
      });

    return () => {
      active = false;
      controller.abort();
    };
  }, [decoded, deviceId]);

  // --- Probe: decide direct play vs HLS -----------------------------------
  useEffect(() => {
    const controller = new AbortController();
    let active = true;
    setLoading(true);
    setError(undefined);
    setInfo(undefined);

    getMediaInfo(decoded, { signal: controller.signal })
      .then((result) => {
        if (!active) return;
        setInfo(result);
        setLoading(false);
      })
      .catch((cause: unknown) => {
        if (!active || controller.signal.aborted) return;
        setError(cause instanceof Error ? cause : new Error(String(cause)));
        setLoading(false);
      });

    return () => {
      active = false;
      controller.abort();
    };
  }, [decoded]);

  const directPlay = info?.direct_play ?? false;
  const mode: PlaybackMode | undefined = info ? playbackModeFor(directPlay) : undefined;

  /**
   * Gate F / AGENTS.md: "Direct streams must remain isolated from transcoding
   * status/polling logic." A direct play has no transcode to wait for, so this
   * effect must not exist for it - not merely render an empty badge.
   */
  useEffect(() => {
    if (!info || directPlay) return;
    if (info.is_transcode_ready) return;

    const controller = new AbortController();
    let active = true;

    const poll = async () => {
      try {
        const status = await getTranscodeStatus(decoded, { signal: controller.signal });
        if (!active) return;
        setTranscode(status);
        if (status.status === 'ready') return; // Stop polling; the effect re-runs on `is_transcode_ready`.
      } catch {
        // Transient poll failure: keep the last known status and try again.
      }
    };

    void poll();
    const timer = window.setInterval(poll, 2000);

    return () => {
      active = false;
      controller.abort();
      window.clearInterval(timer);
    };
  }, [decoded, info, directPlay]);

  // --- Attach the media source --------------------------------------------
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !mode) return;

    const src = playbackUrlFor(decoded, mode);
    let destroyed = false;
    // Type is inferred at runtime from the dynamic import below; declared
    // structurally so the cleanup can call `destroy()` without a static import.
    let hls: { destroy: () => void } | undefined;

    const teardown = () => {
      destroyed = true;
      hls?.destroy();
      // Leave no media resource behind when navigating away mid-playback.
      video.removeAttribute('src');
      video.load();
    };

    if (mode === 'hls') {
      if (video.canPlayType('application/vnd.apple.mpegurl')) {
        // Safari plays HLS natively; instantiating Hls.js there would
        // double-load the playlist for no benefit.
        video.src = src;
        return teardown;
      }

      /*
       * hls.js is ~400 kB and only needed for MKV/HEVC titles. Importing it
       * statically put it in the initial chunk and blew the Gate E budget for
       * every user, including the majority whose direct-play MP4s never touch
       * it. The dynamic import keeps it in a separate chunk that a direct-play
       * viewer never downloads.
       */
      void import('hls.js')
        .then(({ default: HlsCtor }) => {
          if (destroyed) return;
          if (!HlsCtor.isSupported()) {
            setError(new Error('This browser cannot play HLS.'));
            return;
          }
          const instance = new HlsCtor({ lowLatencyMode: true });
          hls = instance;
          instance.loadSource(src);
          instance.attachMedia(video);
          instance.on(HlsCtor.Events.ERROR, (_event, data) => {
            if (!data.fatal) return;
            if (data.type === HlsCtor.ErrorTypes.NETWORK_ERROR) instance.startLoad();
            else if (data.type === HlsCtor.ErrorTypes.MEDIA_ERROR) instance.recoverMediaError();
            else setError(new Error(`HLS playback failed: ${data.details}`));
          });
        })
        .catch(() => {
          if (!destroyed) setError(new Error('Failed to load the HLS playback engine.'));
        });
    } else {
      // Direct play: the browser issues RFC 7233 range requests itself.
      video.src = src;
    }

    return teardown;
  }, [decoded, mode]);

  // --- Persist resume progress --------------------------------------------
  const reportProgress = useCallback(
    (next: number, total: number) => {
      if (!total || !Number.isFinite(next)) return;
      /*
       * Best-effort by design. A failed resume write must never surface as an
       * unhandled rejection - progress is telemetry, and playback must not be
       * affected by whether the POST succeeded.
       */
      void setProgress({
        filename: decoded,
        position: Math.floor(next),
        duration: Math.floor(total),
      }, { deviceId }).catch(() => undefined);
    },
    [decoded, deviceId],
  );

  useEffect(() => {
    if (!playing) return;
    const timer = window.setInterval(() => {
      const video = videoRef.current;
      if (!video) return;
      // Throttle so a 2x speed-up or a 5-minute seek cannot spam the endpoint.
      // Both sides of this comparison are seconds.
      if (video.currentTime - lastReportedRef.current < PROGRESS_INTERVAL_SECONDS) return;
      lastReportedRef.current = video.currentTime;
      reportProgress(video.currentTime, video.duration || duration);
    }, 2000);

    return () => window.clearInterval(timer);
  }, [playing, reportProgress, duration]);

  /*
   * Flush on unmount so navigating away does not lose the last position.
   *
   * The position is mirrored into plain refs rather than read back off the DOM
   * node during cleanup. Two things make reading the node at teardown
   * unreliable:
   *   - the <video> does not exist on the first render (it appears once the
   *     probe resolves), so a ref captured at effect-setup time is `null`; and
   *   - React detaches refs during unmount *before* running effect cleanups, so
   *     `videoRef.current` is already `null` by the time the cleanup runs.
   *
   * Both failure modes look identical: the flush never fires and the final
   * position of every session is silently lost. `timeupdate` keeps these refs
   * current during playback, which is exactly when the value matters.
   */
  useEffect(() => {
    return () => {
      if (lastDurationRef.current > 0 && lastPositionRef.current > 0) {
        reportProgress(lastPositionRef.current, lastDurationRef.current);
      }
    };
  }, [reportProgress]);

  const onLoadedMetadata = () => {
    const video = videoRef.current;
    if (!video) return;
    setDuration(video.duration);
    lastDurationRef.current = video.duration || info?.duration || 0;

    /*
     * Resume, but only when there is something worth resuming. Two guards:
     *   - below 30s, the viewer has barely started and is better off at 0;
     *   - within the last 3%, the title is effectively finished.
     * Without these, a finished film reopens on its final frame, which reads
     * as a broken player rather than a completed one.
     */
    const resumeAt = resumePositionRef.current;
    if (
      resumeAt > RESUME_MIN_SECONDS &&
      video.duration > 0 &&
      resumeAt < video.duration * RESUME_TAIL_RATIO
    ) {
      video.currentTime = resumeAt;
      lastPositionRef.current = resumeAt;
      setPosition(resumeAt);
    }
  };

  /** Keep the mirrored refs in step with playback. */
  const handleTimeUpdate = (time: number) => {
    lastPositionRef.current = time;
    setPosition(time);
  };

  const togglePlay = () => {
    const video = videoRef.current;
    if (!video) return;
    if (video.paused) void video.play();
    else video.pause();
  };

  /**
   * Commit the seek on change (the native range control fires continuously).
   * AGENTS.md forbids synchronously assigning `currentTime` on every
   * seek-bar drag event; the range input's own value drives the UI and the
   * assignment happens here, on the committed event.
   */
  const onSeek = (value: number) => {
    const video = videoRef.current;
    lastPositionRef.current = value;
    setPosition(value);
    if (video) video.currentTime = value;
  };

  if (error) {
    return (
      <div className="rounded-xl border border-brand-500/40 bg-brand-500/10 p-6" role="alert">
        <p className="text-sm font-semibold text-brand-400">Playback unavailable</p>
        <p className="mt-1 text-xs text-white/60">{error.message}</p>
      </div>
    );
  }

  if (loading || !info || !mode) {
    return (
      <div className="space-y-4 animate-fade-in" role="status" aria-label="Probing media">
        <div className="flex items-center justify-between px-1">
          <div className="h-8 w-32 rounded-full bg-white/10 shimmer" />
          <div className="h-5 w-24 rounded-full bg-white/10 shimmer" />
        </div>
        <div className="relative aspect-video w-full rounded-2xl sm:rounded-3xl bg-black ring-1 ring-white/10 shadow-2xl flex flex-col items-center justify-center p-6 text-center">
          <div className="relative mb-5 flex items-center justify-center">
            <div className="absolute h-16 w-16 rounded-full bg-brand-500/20 blur-xl animate-pulse" />
            <div className="h-12 w-12 rounded-full border-2 border-white/10 border-t-brand-500 animate-spin" />
            <div className="absolute h-4 w-4 rounded-full bg-brand-500/80 blur-xs" />
          </div>
          <p className="text-sm font-semibold tracking-wide text-white/90 animate-pulse">
            Probing media…
          </p>
          <p className="mt-1 text-xs text-white/40 max-w-sm">
            Initializing video stream & hardware decoder
          </p>
        </div>
      </div>
    );
  }

  const ready = directPlay || info.is_transcode_ready;

  const title = decoded.split('/').pop()?.replace(/\.[^/.]+$/, '') ?? decoded;

  return (
    <div className="space-y-4 animate-fade-in" data-testid="player" data-mode={mode}>
      {/* Player Top Navigation Bar */}
      <div className="flex flex-wrap items-center justify-between gap-3 px-1">
        <Link
          to={`/movie/${decoded.split('/').map(encodeURIComponent).join('/')}`}
          className="inline-flex items-center gap-2 rounded-full border border-white/15 bg-white/5 px-4 py-1.5 text-xs font-semibold text-white/80 shadow-sm transition hover:border-white/30 hover:bg-white/10 hover:text-white active:scale-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-400"
        >
          <Icon name="arrow-left" size={13} />
          <span>Back to Movie</span>
        </Link>

        <div className="flex items-center gap-2">
          <span className="truncate max-w-xs sm:max-w-md text-xs font-medium text-white/60">
            {title}
          </span>
          <span className={`rounded-full px-2.5 py-0.5 font-mono text-[10px] font-semibold uppercase tracking-wider ${
            mode === 'direct'
              ? 'bg-emerald-500/15 text-emerald-300 border border-emerald-500/30'
              : 'bg-amber-500/15 text-amber-300 border border-amber-500/30'
          }`}>
            {mode === 'direct' ? 'Direct Play' : 'HLS Stream'}
          </span>
        </div>
      </div>

      {!ready ? (
        <div className="glass-card rounded-2xl p-6 text-center shadow-xl animate-fade-in">
          <div className="mx-auto mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-brand-500/20 text-brand-400">
            <Icon name="bolt" size={20} />
          </div>
          <p className="text-base font-bold text-white">
            Building a transcode for this title
          </p>
          <p className="mt-1 text-xs text-white/50 max-w-md mx-auto">
            {transcode
              ? `${Math.round(transcode.percent)}% encoded · ${transcode.speed}× transcode speed · ETA ${formatClock(transcode.remaining ?? 0)}`
              : 'The first play of an MKV/HEVC title dynamically prepares HLS chunks via dual AMD GPUs.'}
          </p>
          {transcode ? (
            <div className="mt-4 max-w-md mx-auto h-2 overflow-hidden rounded-full bg-white/10">
              <div
                className="brand-gradient brand-glow h-full transition-[width] duration-300"
                style={{ width: `${transcode.percent}%` }}
              />
            </div>
          ) : null}
        </div>
      ) : null}

      {/* Video Container */}
      <div className="relative overflow-hidden rounded-2xl sm:rounded-3xl bg-black ring-1 ring-white/10 shadow-2xl">
        <video
          ref={videoRef}
          className="aspect-video w-full bg-black object-contain"
          controls
          playsInline
          preload="metadata"
          onLoadedMetadata={onLoadedMetadata}
          onPlay={() => setPlaying(true)}
          onPause={() => setPlaying(false)}
          onTimeUpdate={(event) => handleTimeUpdate(event.currentTarget.currentTime)}
        />
      </div>

      {/* Modern Controls Ribbon */}
      <div className="glass-card flex flex-wrap items-center gap-3 sm:gap-4 rounded-2xl p-3 sm:p-4 shadow-xl">
        <button
          type="button"
          onClick={togglePlay}
          disabled={!ready}
          className="brand-gradient brand-glow-sm flex items-center gap-2 rounded-full px-5 py-2 text-xs sm:text-sm font-bold text-white shadow-md transition hover:scale-105 active:scale-95 disabled:opacity-40"
        >
          {playing ? (
            <>
              <span>⏸</span>
              <span>Pause</span>
            </>
          ) : (
            <>
              <Icon name="play" size={13} className="text-white" />
              <span>Play</span>
            </>
          )}
        </button>

        <button
          type="button"
          onClick={() => onSeek(0)}
          disabled={!ready}
          title="Restart video from beginning"
          className="rounded-full border border-white/15 bg-white/5 px-3 py-2 text-xs font-semibold text-white/80 transition hover:bg-white/10 hover:text-white disabled:opacity-40"
        >
          <Icon name="rotate" size={14} />
        </button>

        <span className="font-mono text-xs text-white/70 tracking-tight">
          <span className="text-white font-semibold">{formatClock(position)}</span> / {formatClock(duration || info.duration)}
        </span>

        {/* Seekbar Slider */}
        <div className="relative flex-1 min-w-[140px] flex items-center">
          <input
            type="range"
            min={0}
            max={duration || info.duration || 0}
            step={0.1}
            value={Math.min(position, duration || info.duration || 0)}
            onChange={(event) => setPosition(Number(event.target.value))}
            onPointerUp={(event) => onSeek(Number((event.target as HTMLInputElement).value))}
            onKeyUp={(event) => onSeek(Number((event.target as HTMLInputElement).value))}
            onTouchEnd={(event) => onSeek(Number((event.target as HTMLInputElement).value))}
            disabled={!ready}
            className="w-full h-1.5 bg-white/20 rounded-lg appearance-none cursor-pointer accent-brand-500 disabled:opacity-30"
            aria-label="Seek"
          />
        </div>

        {/* Fullscreen Button */}
        <button
          type="button"
          onClick={() => {
            if (videoRef.current) {
              if (document.fullscreenElement) {
                void document.exitFullscreen();
              } else {
                void videoRef.current.requestFullscreen();
              }
            }
          }}
          disabled={!ready}
          title="Toggle fullscreen"
          className="rounded-full border border-white/15 bg-white/5 p-2 text-white/70 hover:bg-white/10 hover:text-white transition disabled:opacity-30"
        >
          <Icon name="ruler" size={14} />
        </button>
      </div>
    </div>
  );
}

export default PlayerPage;