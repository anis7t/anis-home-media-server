import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useParams } from 'react-router';
import { Icon } from '../../components/icons';
import { PlayerSeekbar } from './PlayerSeekbar';
import {
  getMediaInfo,
  getProgress,
  getTranscodeStatus,
  setProgress,
} from '../../lib/api/client';
import { playbackModeFor, playbackUrlFor, type PlaybackMode } from '../../lib/api/media';
import { useDeviceId } from '../../lib/useDeviceId';
import type { MediaInfoResponse, TranscodeStatusResponse } from '../../lib/api/types';
import { useSubtitles } from './useSubtitles';
import { SubtitleSettingsModal } from './SubtitleSettingsModal';
import { NerdStatsHud } from './NerdStatsHud';
import { ShortcutsModal } from './ShortcutsModal';
import { PlayerPreloader } from './PlayerPreloader';
import { SeekRipples } from './SeekRipples';
import { TranscodeCard, CacheStatusDialog, ShellTranscodePill } from './TranscodeCard';
import { TranscodeGate } from './TranscodeGate';
import { CastModal } from './CastModal';
import { CastBar } from './CastBar';
import {
  startCastPlay,
  sendCastControl,
  getCastStatus,
  stopCast,
  type CastDevice,
  type CastStatusResponse,
} from '../../lib/api/cast';

export const ASPECT_MODES = [
  { id: 'fit', label: 'Fit', name: 'Best Fit' },
  { id: 'crop', label: 'Crop', name: 'Crop (Zoom)' },
  { id: 'stretch', label: 'Stretch', name: 'Stretch' },
  { id: '16-9', label: '16:9', name: '16:9' },
  { id: '4-3', label: '4:3', name: '4:3' },
  { id: 'orig', label: 'Orig', name: 'Original' },
] as const;

export type AspectMode = (typeof ASPECT_MODES)[number]['id'];
const ASPECT_KEY = 'media_aspect_mode';

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
  const [bufferedRanges, setBufferedRanges] = useState<{ start: number; end: number }[]>([]);
  const [volume, setVolume] = useState(1);
  const [muted, setMuted] = useState(false);
  const [speed, setSpeed] = useState(1);
  const [showRemainingTime, setShowRemainingTime] = useState(() => {
    try {
      return localStorage.getItem('media_show_remaining') === '1';
    } catch {
      return false;
    }
  });
  const [aspectMode, setAspectMode] = useState<AspectMode>(() => {
    try {
      const saved = localStorage.getItem(ASPECT_KEY);
      if (saved && ASPECT_MODES.some((m) => m.id === saved)) {
        return saved as AspectMode;
      }
    } catch {
      // Ignore localStorage errors
    }
    return 'fit';
  });
  const [rotationDeg, setRotationDeg] = useState<0 | 90 | 180 | 270>(0);
  const [isPipActive, setIsPipActive] = useState(false);
  const [isNerdStatsOpen, setIsNerdStatsOpen] = useState(false);
  const [isShortcutsOpen, setIsShortcutsOpen] = useState(false);

  const [controlsVisible, setControlsVisible] = useState(true);
  const [isScrubbing, setIsScrubbing] = useState(false);
  const controlsTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Cast state
  const [castModalOpen, setCastModalOpen] = useState(false);
  const [activeCastDevice, setActiveCastDevice] = useState<CastDevice | null>(null);
  const [connectingCastDeviceId, setConnectingCastDeviceId] = useState<string | null>(null);
  const [castStatus, setCastStatus] = useState<CastStatusResponse | null>(null);

  const [preloaderVisible, setPreloaderVisible] = useState(true);
  const [rippleLeft, setRippleLeft] = useState(false);
  const [rippleRight, setRippleRight] = useState(false);
  const [rippleLeftSec, setRippleLeftSec] = useState(10);
  const [rippleRightSec, setRippleRightSec] = useState(10);
  const rippleTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const triggerRipple = useCallback((side: 'left' | 'right', sec: number) => {
    if (side === 'left') {
      setRippleLeft(true);
      setRippleRight(false);
      setRippleLeftSec(sec);
    } else {
      setRippleRight(true);
      setRippleLeft(false);
      setRippleRightSec(sec);
    }
    if (rippleTimerRef.current) clearTimeout(rippleTimerRef.current);
    rippleTimerRef.current = setTimeout(() => {
      setRippleLeft(false);
      setRippleRight(false);
    }, 650);
  }, []);

  // Preloader auto-dismiss fallback timer
  useEffect(() => {
    const timer = setTimeout(() => {
      setPreloaderVisible(false);
    }, 2500);
    return () => clearTimeout(timer);
  }, []);


  const resetControlsTimer = useCallback(() => {
    setControlsVisible(true);
    if (controlsTimerRef.current) clearTimeout(controlsTimerRef.current);
    if (playing && !isScrubbing) {
      controlsTimerRef.current = setTimeout(() => {
        setControlsVisible(false);
      }, 2500);
    }
  }, [playing, isScrubbing]);

  const lastReportedRef = useRef(0);
  /** Mirrored position/duration, readable at teardown when the node is gone. */
  const lastPositionRef = useRef(0);
  const lastDurationRef = useRef(0);
  const resumePositionRef = useRef(0);
  const deviceId = useDeviceId();

  const [hudMessage, setHudMessage] = useState<string | null>(null);
  const hudTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const showHud = useCallback((text: string) => {
    setHudMessage(text);
    if (hudTimerRef.current) clearTimeout(hudTimerRef.current);
    hudTimerRef.current = setTimeout(() => {
      setHudMessage(null);
    }, 1600);
  }, []);

  const {
    tracks,
    activeTrackIndex,
    prefs: subPrefs,
    isSettingsOpen: isSubModalOpen,
    setIsSettingsOpen: setIsSubModalOpen,
    selectTrack,
    toggleCC,
    updatePref: updateSubPref,
    uploadSubtitle,
    elevateCues,
  } = useSubtitles(videoRef, decoded, showHud);

  // Elevate WebVTT cues when controls appear/hide
  useEffect(() => {
    elevateCues();
  }, [controlsVisible, isScrubbing, playing, elevateCues]);

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
   * 100% Transcode Completion & Playback Ready Gate:
   * Playback and frame previews require 100% ready files (direct stream or 100% transcoded).
   * Incomplete transcoded videos MUST NOT play to prevent playback issues, stalls, and timeline drift.
   */
  const isTranscodeComplete = Boolean(
    directPlay ||
    info?.is_transcode_ready ||
    (transcode?.status === 'ready' && (transcode?.percent ?? 0) >= 100),
  );
  const isPlaybackReady = directPlay || isTranscodeComplete;

  /**
   * Gate F / AGENTS.md: "Direct streams must remain isolated from transcoding
   * status/polling logic." A direct play has no transcode to wait for, so this
   * effect must not exist for it - not merely render an empty badge.
   */
  useEffect(() => {
    if (!info || directPlay || isTranscodeComplete) return;

    const controller = new AbortController();
    let active = true;

    const poll = async () => {
      try {
        const status = await getTranscodeStatus(decoded, { signal: controller.signal });
        if (!active) return;
        setTranscode(status);
        if (status.status === 'ready' && (status.percent ?? 0) >= 100) {
          showHud('Transcode 100% complete — Ready to play');
          return;
        }
      } catch {
        // Transient poll failure: keep the last known status and try again.
      }
    };

    void poll();
    const timer = window.setInterval(poll, 1500);

    return () => {
      active = false;
      controller.abort();
      window.clearInterval(timer);
    };
  }, [decoded, info, directPlay, isTranscodeComplete, showHud]);

  // Poll Cast status when casting is active
  useEffect(() => {
    if (!activeCastDevice) return;

    const controller = new AbortController();
    let active = true;

    const poll = async () => {
      try {
        const res = await getCastStatus(activeCastDevice.id, { signal: controller.signal });
        if (!active) return;
        setCastStatus(res);
      } catch {
        // Status polling transient failure
      }
    };

    void poll();
    const timer = window.setInterval(poll, 1500);

    return () => {
      active = false;
      window.clearInterval(timer);
      controller.abort();
    };
  }, [activeCastDevice]);

  const handleSelectCastDevice = async (device: CastDevice) => {
    setConnectingCastDeviceId(device.id);
    try {
      const video = videoRef.current;
      if (video) {
        video.pause();
        setPlaying(false);
      }
      const currentPos = position;
      const res = await startCastPlay(device.id, decoded, { position: currentPos });
      if (res.ok) {
        setActiveCastDevice(device);
        setCastModalOpen(false);
        showHud(`Casting to ${device.name}`);
      } else {
        showHud(res.error || `Could not cast to ${device.name}`);
      }
    } catch (err) {
      showHud(err instanceof Error ? err.message : 'Cast connection failed');
    } finally {
      setConnectingCastDeviceId(null);
    }
  };

  const handleCastControl = async (
    action: 'play' | 'pause' | 'stop' | 'seek' | 'volume',
    value?: number,
  ) => {
    if (!activeCastDevice) return;
    try {
      await sendCastControl(activeCastDevice.id, action, value);
      if (action === 'play') setCastStatus((s) => (s ? { ...s, state: 'playing' } : null));
      if (action === 'pause') setCastStatus((s) => (s ? { ...s, state: 'paused' } : null));
      if (action === 'seek' && value !== undefined) setCastStatus((s) => (s ? { ...s, position: value } : null));
      if (action === 'volume' && value !== undefined) setCastStatus((s) => (s ? { ...s, volume: value } : null));
    } catch (err) {
      showHud(err instanceof Error ? err.message : 'Remote control failed');
    }
  };

  const handleDisconnectCast = async () => {
    if (!activeCastDevice) return;
    const deviceName = activeCastDevice.name;
    const resumePos = castStatus?.position ?? position;
    try {
      await stopCast(activeCastDevice.id);
    } catch {
      // Disconnect non-fatal
    }
    setActiveCastDevice(null);
    setCastStatus(null);
    showHud(`Disconnected from ${deviceName}`);
    if (videoRef.current) {
      videoRef.current.currentTime = resumePos;
      setPosition(resumePos);
    }
  };

  // --- Attach the media source (strictly locked until 100% ready) -----------
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !mode || !isPlaybackReady) return;

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

  const updateBuffered = (v: HTMLVideoElement) => {
    if (!v.buffered || v.buffered.length === 0) return;
    const ranges: { start: number; end: number }[] = [];
    for (let i = 0; i < v.buffered.length; i++) {
      ranges.push({ start: v.buffered.start(i), end: v.buffered.end(i) });
    }
    setBufferedRanges(ranges);
  };

  /** Keep the mirrored refs in step with playback. */
  const handleTimeUpdate = (time: number) => {
    lastPositionRef.current = time;
    setPosition(time);
    if (videoRef.current) {
      updateBuffered(videoRef.current);
    }
  };

  const togglePlay = () => {
    const video = videoRef.current;
    if (!video) return;
    if (video.paused) {
      void video.play().catch(() => {});
    } else {
      video.pause();
    }
    resetControlsTimer();
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
    resetControlsTimer();
  };

  const handleSkip = useCallback(
    (deltaSeconds: number) => {
      const total = duration || info?.duration || 0;
      const current = position;
      const target = Math.max(0, Math.min(total, current + deltaSeconds));
      onSeek(target);
      if (deltaSeconds < 0) {
        triggerRipple('left', Math.abs(deltaSeconds));
      } else if (deltaSeconds > 0) {
        triggerRipple('right', deltaSeconds);
      }
    },
    [duration, info?.duration, position, onSeek, triggerRipple],
  );

  const toggleMute = () => {
    const v = videoRef.current;
    if (!v) return;
    v.muted = !v.muted;
    setMuted(v.muted);
    resetControlsTimer();
  };

  const handleVolumeChange = (newVol: number) => {
    const v = videoRef.current;
    if (!v) return;
    v.volume = newVol;
    v.muted = false;
    setVolume(newVol);
    setMuted(false);
    resetControlsTimer();
  };

  const handleSpeedChange = (newSpeed: number) => {
    const v = videoRef.current;
    if (!v) return;
    v.playbackRate = newSpeed;
    setSpeed(newSpeed);
    resetControlsTimer();
  };

  const toggleRemainingTime = () => {
    setShowRemainingTime((prev) => {
      const next = !prev;
      try {
        localStorage.setItem('media_show_remaining', next ? '1' : '0');
      } catch {
        // Ignore localStorage errors
      }
      return next;
    });
  };

  const nextAspect = useCallback(() => {
    setAspectMode((prev) => {
      const curIdx = ASPECT_MODES.findIndex((m) => m.id === prev);
      const nextIdx = (curIdx + 1) % ASPECT_MODES.length;
      const nextMode = ASPECT_MODES[nextIdx];
      try {
        localStorage.setItem(ASPECT_KEY, nextMode.id);
      } catch {
        // Ignore localStorage errors
      }
      showHud(`Aspect: ${nextMode.name}`);
      return nextMode.id;
    });
    resetControlsTimer();
  }, [resetControlsTimer, showHud]);

  const toggleRotation = useCallback(() => {
    const screenAny = window.screen as unknown as {
      orientation?: { type?: string; lock?: (target: string) => Promise<void> };
    };
    if (screenAny?.orientation && typeof screenAny.orientation.lock === 'function') {
      try {
        const isPortrait =
          screenAny.orientation.type?.startsWith('portrait') || window.innerHeight > window.innerWidth;
        const target = isPortrait ? 'landscape' : 'portrait';
        void screenAny.orientation
          .lock(target)
          .then(() => {
            showHud(`🔄 Screen: ${target === 'landscape' ? 'Landscape' : 'Portrait'}`);
          })
          .catch(() => {
            // Fall back to software rotation
          });
      } catch {
        // Fall back to software rotation
      }
    }

    setRotationDeg((prev) => {
      const next = ((prev + 90) % 360) as 0 | 90 | 180 | 270;
      showHud(`🔄 Rotate: ${next}°`);
      return next;
    });
    resetControlsTimer();
  }, [resetControlsTimer, showHud]);

  const togglePip = useCallback(async () => {
    try {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture();
        showHud('Exited Picture-in-Picture');
      } else if (videoRef.current?.requestPictureInPicture) {
        await videoRef.current.requestPictureInPicture();
        showHud('📺 Picture-in-Picture');
      }
    } catch {
      // Ignore PiP errors
    }
    resetControlsTimer();
  }, [resetControlsTimer, showHud]);

  const toggleFullscreen = useCallback(() => {
    const shell = document.getElementById('shell');
    if (document.fullscreenElement) {
      void document.exitFullscreen().catch(() => {});
    } else if (shell) {
      void shell.requestFullscreen().catch(() => {});
    }
    resetControlsTimer();
  }, [resetControlsTimer]);

  useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    const onEnter = () => setIsPipActive(true);
    const onLeave = () => setIsPipActive(false);
    v.addEventListener('enterpictureinpicture', onEnter);
    v.addEventListener('leavepictureinpicture', onLeave);
    return () => {
      v.removeEventListener('enterpictureinpicture', onEnter);
      v.removeEventListener('leavepictureinpicture', onLeave);
    };
  }, []);

  const getRotationScale = useCallback(() => {
    const shell = videoRef.current?.parentElement;
    if (!shell) return 1;
    const r = shell.getBoundingClientRect();
    return r.width > 0 && r.height > 0 ? (r.height / r.width).toFixed(4) : 1;
  }, []);

  const controlsVisibleAtInteractionStart = useRef(true);
  const lastTapTimeRef = useRef(0);
  const tapTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const accumulatedSideRef = useRef<'left' | 'right' | null>(null);
  const accumulatedSecRef = useRef(0);

  const handleShellPointerDown = useCallback((e: React.PointerEvent<HTMLDivElement>) => {
    const target = e.target as HTMLElement | null;
    if (!target) return;
    if (
      target.closest(
        '#controls, .player-controls-overlay, .sub-modal, .nerd-stats-hud, #nerdStatsBtn, .watch-back, #full, #restartBtn, #center, #skipBackBtn, #skipForwardBtn, #shortcutsBtn, #ccMergedPill, #aspectBtn, #rotateBtn, #pipBtn, button, input, select, label, a',
      )
    ) {
      return;
    }
    const shellEl = e.currentTarget;
    const isShown = shellEl.classList.contains('show') && controlsVisible;
    controlsVisibleAtInteractionStart.current = isShown;
    if (isShown) {
      resetControlsTimer();
    }
  }, [controlsVisible, resetControlsTimer]);

  const handleShellClick = useCallback((e: React.MouseEvent<HTMLDivElement>) => {
    const target = e.target as HTMLElement | null;
    if (!target) return;
    if (
      target.closest(
        '#controls, .player-controls-overlay, .sub-modal, .nerd-stats-hud, #nerdStatsBtn, .watch-back, #full, #restartBtn, #center, #skipBackBtn, #skipForwardBtn, #shortcutsBtn, #ccMergedPill, #aspectBtn, #rotateBtn, #pipBtn, button, input, select, label, a',
      )
    ) {
      return;
    }

    // Dismiss any active modals on outside click
    if (isSubModalOpen) {
      setIsSubModalOpen(false);
      return;
    }
    if (isShortcutsOpen) {
      setIsShortcutsOpen(false);
      return;
    }
    if (isNerdStatsOpen) {
      setIsNerdStatsOpen(false);
      return;
    }

    const shellEl = e.currentTarget;
    const rect = shellEl.getBoundingClientRect();
    const relX = (e.clientX - rect.left) / rect.width;
    const now = Date.now();

    const isLeftZone = relX < 0.4;
    const isRightZone = relX > 0.6;
    const isDoubleTap = now - lastTapTimeRef.current < 300;

    if (isDoubleTap && isLeftZone) {
      if (tapTimerRef.current) {
        clearTimeout(tapTimerRef.current);
        tapTimerRef.current = null;
      }
      const nextSec = accumulatedSideRef.current === 'left' ? accumulatedSecRef.current + 10 : 10;
      accumulatedSideRef.current = 'left';
      accumulatedSecRef.current = nextSec;
      handleSkip(-10);
      triggerRipple('left', nextSec);
      lastTapTimeRef.current = now;
      resetControlsTimer();
      return;
    }

    if (isDoubleTap && isRightZone) {
      if (tapTimerRef.current) {
        clearTimeout(tapTimerRef.current);
        tapTimerRef.current = null;
      }
      const nextSec = accumulatedSideRef.current === 'right' ? accumulatedSecRef.current + 10 : 10;
      accumulatedSideRef.current = 'right';
      accumulatedSecRef.current = nextSec;
      handleSkip(10);
      triggerRipple('right', nextSec);
      lastTapTimeRef.current = now;
      resetControlsTimer();
      return;
    }

    // Not a double-tap: reset accumulator and queue single-tap action
    lastTapTimeRef.current = now;
    accumulatedSideRef.current = null;
    accumulatedSecRef.current = 0;

    const wasVisible = controlsVisibleAtInteractionStart.current;
    if (tapTimerRef.current) clearTimeout(tapTimerRef.current);

    tapTimerRef.current = setTimeout(() => {
      tapTimerRef.current = null;
      if (!wasVisible) {
        // Tap-to-reveal: reveal controls only, do NOT toggle playback
        setControlsVisible(true);
        shellEl.classList.add('show');
        resetControlsTimer();
      } else {
        // Controls were already visible: toggle play/pause
        togglePlay();
      }
    }, 280);
  }, [
    isSubModalOpen,
    isShortcutsOpen,
    isNerdStatsOpen,
    setIsSubModalOpen,
    handleSkip,
    triggerRipple,
    resetControlsTimer,
    togglePlay,
  ]);

  // Comprehensive keyboard shortcuts (Space, k, arrows, j, l, 0-9, m, f, p/i, a, r, n, c, <, >, ?, Escape)
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (
        (e.target instanceof HTMLInputElement && e.target.type !== 'range') ||
        e.target instanceof HTMLTextAreaElement ||
        e.target instanceof HTMLSelectElement
      ) {
        if (e.key === 'Escape') {
          (e.target as HTMLElement).blur();
        }
        return;
      }

      // Escape dismisses any open modal first
      if (e.key === 'Escape') {
        if (isNerdStatsOpen) {
          setIsNerdStatsOpen(false);
          return;
        }
        if (isShortcutsOpen) {
          setIsShortcutsOpen(false);
          return;
        }
        if (isSubModalOpen) {
          setIsSubModalOpen(false);
          return;
        }
        return;
      }

      // Play / Pause
      if (e.code === 'Space' || e.key === 'k' || e.key === 'K') {
        e.preventDefault();
        togglePlay();
        return;
      }

      // Replay from start
      if (e.key === 'Home' || e.key === '0') {
        e.preventDefault();
        onSeek(0);
        showHud('↺ Played from start');
        return;
      }

      // Seeks: ±5s via arrows, ±10s via j/l
      if (e.code === 'ArrowLeft') {
        e.preventDefault();
        handleSkip(-5);
        return;
      }
      if (e.code === 'ArrowRight') {
        e.preventDefault();
        handleSkip(5);
        return;
      }
      if (e.key === 'j' || e.key === 'J') {
        e.preventDefault();
        handleSkip(-10);
        return;
      }
      if (e.key === 'l' || e.key === 'L') {
        e.preventDefault();
        handleSkip(10);
        return;
      }

      // Percentage seek 1-9 (10%-90%)
      if (/^[1-9]$/.test(e.key)) {
        e.preventDefault();
        const total = duration || info?.duration || 0;
        if (total > 0) {
          const pct = Number(e.key) * 0.1;
          onSeek(total * pct);
          showHud(`Seek: ${Math.round(pct * 100)}%`);
        }
        return;
      }

      // Volume: ↑ / ↓ (±5%)
      if (e.code === 'ArrowUp') {
        e.preventDefault();
        const newVol = Math.min(1, volume + 0.05);
        handleVolumeChange(newVol);
        showHud(`🔊 ${Math.round(newVol * 100)}%`);
        return;
      }
      if (e.code === 'ArrowDown') {
        e.preventDefault();
        const newVol = Math.max(0, volume - 0.05);
        handleVolumeChange(newVol);
        showHud(`🔊 ${Math.round(newVol * 100)}%`);
        return;
      }

      // Mute
      if (e.key === 'm' || e.key === 'M') {
        e.preventDefault();
        toggleMute();
        showHud(!muted ? '🔇 Muted' : `🔊 ${Math.round(volume * 100)}%`);
        return;
      }

      // Fullscreen
      if (e.key === 'f' || e.key === 'F') {
        e.preventDefault();
        toggleFullscreen();
        return;
      }

      // Picture-in-Picture
      if (e.key === 'p' || e.key === 'P' || e.key === 'i' || e.key === 'I') {
        e.preventDefault();
        void togglePip();
        return;
      }

      // Aspect ratio
      if (e.key === 'a' || e.key === 'A') {
        e.preventDefault();
        nextAspect();
        return;
      }

      // Rotate screen
      if (e.key === 'r' || e.key === 'R') {
        e.preventDefault();
        toggleRotation();
        return;
      }

      // Stats for nerds
      if (e.key === 'n' || e.key === 'N') {
        e.preventDefault();
        setIsNerdStatsOpen((prev) => !prev);
        resetControlsTimer();
        return;
      }

      // Subtitles
      if (e.key === 'c' || e.key === 'C') {
        e.preventDefault();
        toggleCC();
        return;
      }

      // Speed adjustment
      const SPEEDS = [0.75, 1, 1.25, 1.5, 2];
      if (e.key === '<' || e.key === ',') {
        e.preventDefault();
        const curIdx = SPEEDS.indexOf(speed);
        if (curIdx > 0) {
          const nextSpd = SPEEDS[curIdx - 1];
          handleSpeedChange(nextSpd);
          showHud(`▶ ${nextSpd}× Speed`);
        }
        return;
      }
      if (e.key === '>' || e.key === '.') {
        e.preventDefault();
        const curIdx = SPEEDS.indexOf(speed);
        if (curIdx >= 0 && curIdx < SPEEDS.length - 1) {
          const nextSpd = SPEEDS[curIdx + 1];
          handleSpeedChange(nextSpd);
          showHud(`▶ ${nextSpd}× Speed`);
        }
        return;
      }

      // Cheat sheet
      if (e.key === '?' || (e.key === '/' && !e.shiftKey)) {
        e.preventDefault();
        setIsShortcutsOpen((prev) => !prev);
        resetControlsTimer();
        return;
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [
    isNerdStatsOpen,
    isShortcutsOpen,
    isSubModalOpen,
    togglePlay,
    onSeek,
    handleSkip,
    duration,
    info,
    volume,
    muted,
    speed,
    handleVolumeChange,
    handleSpeedChange,
    toggleMute,
    toggleFullscreen,
    togglePip,
    nextAspect,
    toggleRotation,
    toggleCC,
    resetControlsTimer,
    showHud,
    setIsSubModalOpen,
  ]);

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

  const ready = isPlaybackReady;

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
          <ShellTranscodePill
            transcode={transcode}
            isReady={isPlaybackReady}
            needsTranscode={mode === 'hls' && !isPlaybackReady}
          />
          <span className={`rounded-full px-2.5 py-0.5 font-mono text-[10px] font-semibold uppercase tracking-wider ${
            mode === 'direct'
              ? 'bg-emerald-500/15 text-emerald-300 border border-emerald-500/30'
              : 'bg-amber-500/15 text-amber-300 border border-amber-500/30'
          }`}>
            {mode === 'direct' ? 'Direct Play' : 'HLS Stream'}
          </span>
        </div>
      </div>

      {/* 100% Transcode Completion Staging Gate (Strict Lock for Non-100% Ready Transcodes) */}
      {!isPlaybackReady ? (
        <TranscodeGate
          filename={decoded}
          transcode={transcode}
          onRefresh={() => {
            void getTranscodeStatus(decoded).then((res) => setTranscode(res)).catch(() => {});
          }}
        />
      ) : activeCastDevice ? (
        <CastBar
          device={activeCastDevice}
          filename={decoded}
          status={castStatus}
          onControl={handleCastControl}
          onDisconnect={handleDisconnectCast}
        />
      ) : null}

      {/* Video Container Shell (strictly hidden until 100% transcode ready and not casting) */}
      <div
        id="shell"
        className={`relative overflow-hidden rounded-2xl sm:rounded-3xl bg-black ring-1 ring-white/10 shadow-2xl group ${
          controlsVisible || isScrubbing || !playing ? 'show' : ''
        } ${!isPlaybackReady || activeCastDevice ? 'hidden' : ''}`}
        style={!isPlaybackReady || activeCastDevice ? { display: 'none' } : undefined}
        onPointerMove={resetControlsTimer}
        onPointerDown={handleShellPointerDown}
        onClick={handleShellClick}
      >
        <video
          id="video"
          ref={videoRef}
          className={`aspect-video w-full bg-black cursor-pointer aspect-${aspectMode} ${
            rotationDeg > 0 ? `rotate-${rotationDeg}` : ''
          }`}
          style={
            rotationDeg === 90 || rotationDeg === 270
              ? { transform: `rotate(${rotationDeg}deg) scale(${getRotationScale()})` }
              : rotationDeg === 180
                ? { transform: 'rotate(180deg)' }
                : undefined
          }
          playsInline
          preload="metadata"
          data-filename={decoded}
          onLoadedMetadata={onLoadedMetadata}
          onLoadedData={() => setPreloaderVisible(false)}
          onCanPlay={() => setPreloaderVisible(false)}
          onPlay={() => {
            setPlaying(true);
            setPreloaderVisible(false);
            resetControlsTimer();
          }}
          onPause={() => {
            setPlaying(false);
            setControlsVisible(true);
          }}
          onTimeUpdate={(event) => handleTimeUpdate(event.currentTarget.currentTime)}
          onProgress={(event) => updateBuffered(event.currentTarget)}
        >
          {tracks.map((t, idx) => (
            <track
              key={t.id || t.src || idx}
              kind="subtitles"
              label={t.label}
              srcLang={t.lang}
              src={t.src}
              default={t.default}
            />
          ))}
        </video>

        {/* Media Preloader Overlay */}
        <PlayerPreloader
          visible={preloaderVisible}
          onDismiss={() => setPreloaderVisible(false)}
        />

        {/* Cache Status Preparation Dialog */}
        <CacheStatusDialog
          transcode={transcode}
          isReady={info.is_transcode_ready}
          needsTranscode={mode === 'hls' && !info.is_transcode_ready}
        />

        {/* Animated Seek Ripples */}
        <SeekRipples
          leftVisible={rippleLeft}
          rightVisible={rippleRight}
          leftSec={rippleLeftSec}
          rightSec={rippleRightSec}
        />

        {/* Live HUD Notification */}
        {hudMessage && (
          <div id="playerHud" className="player-hud">
            {hudMessage}
          </div>
        )}

        {/* Center Big Play/Pause Button */}
        {!playing && ready && (
          <button
            id="center"
            type="button"
            onClick={togglePlay}
            aria-label="Play"
            className="absolute inset-0 m-auto flex h-20 w-20 items-center justify-center rounded-full bg-black/60 text-white shadow-2xl backdrop-blur-md transition-all duration-300 hover:scale-110 hover:bg-brand-600/80 active:scale-95"
          >
            <Icon name="play" size={32} className="ml-1 text-white" />
          </button>
        )}

        {/* Controls Overlay Ribbon */}
        <div id="controls" className="player-controls-overlay absolute inset-x-0 bottom-0 z-30 p-3 sm:p-5 bg-gradient-to-t from-black/95 via-black/70 to-transparent">
          {/* YouTube Seekbar */}
          <div className="mb-3">
            <PlayerSeekbar
              filename={decoded}
              duration={duration || info.duration || 0}
              currentTime={position}
              buffered={bufferedRanges}
              onSeek={onSeek}
              onScrubbingChange={(scrub) => {
                setIsScrubbing(scrub);
                if (scrub) setControlsVisible(true);
                else resetControlsTimer();
              }}
              canPreview={isPlaybackReady}
              disabled={!ready}
            />
          </div>

          <div className="flex flex-wrap items-center justify-between gap-3 text-white">
            <div className="flex items-center gap-2 sm:gap-3">
              {/* Play / Pause button */}
              <button
                id="play"
                type="button"
                onClick={togglePlay}
                disabled={!ready}
                title="Play / Pause (Space / k)"
                className="brand-gradient brand-glow-sm flex h-9 w-9 sm:h-10 sm:w-10 items-center justify-center rounded-full text-white shadow-md transition hover:scale-105 active:scale-95 disabled:opacity-40"
              >
                {playing ? (
                  <span className="text-sm font-bold">⏸</span>
                ) : (
                  <Icon name="play" size={15} className="ml-0.5 text-white" />
                )}
              </button>

              {/* Restart button */}
              <button
                id="restartBtn"
                type="button"
                onClick={() => onSeek(0)}
                disabled={!ready}
                title="Play from beginning"
                className="flex h-8 w-8 sm:h-9 sm:w-9 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/80 transition hover:bg-white/10 hover:text-white disabled:opacity-40"
              >
                <Icon name="rotate" size={14} />
              </button>

              {/* Skip Back 10s */}
              <button
                id="skipBackBtn"
                type="button"
                onClick={() => handleSkip(-10)}
                disabled={!ready}
                title="Rewind 10s (j / ←)"
                className="flex h-8 w-8 sm:h-9 sm:w-9 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/80 transition hover:bg-white/10 hover:text-white disabled:opacity-40"
              >
                <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                  <path d="M12 5V1L7 6l5 5V7c3.31 0 6 2.69 6 6s-2.69 6-6 6-6-2.69-6-6H4c0 4.42 3.58 8 8 8s8-3.58 8-8-3.58-8-8-8z" />
                  <text x="12" y="15" fontSize="6.5" fontWeight="800" textAnchor="middle" fill="currentColor">10</text>
                </svg>
              </button>

              {/* Skip Forward 10s */}
              <button
                id="skipForwardBtn"
                type="button"
                onClick={() => handleSkip(10)}
                disabled={!ready}
                title="Fast Forward 10s (l / →)"
                className="flex h-8 w-8 sm:h-9 sm:w-9 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/80 transition hover:bg-white/10 hover:text-white disabled:opacity-40"
              >
                <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                  <path d="M12 5V1l5 5-5 5V7c-3.31 0-6 2.69-6 6s2.69 6 6 6 6-2.69 6-6h2c0 4.42-3.58 8-8 8s-8-3.58-8-8 8-8 8-8z" />
                  <text x="12" y="15" fontSize="6.5" fontWeight="800" textAnchor="middle" fill="currentColor">10</text>
                </svg>
              </button>

              {/* Time display */}
              <div className="flex items-center gap-1 font-mono text-xs text-white/70 tracking-tight ml-1">
                <span id="timeElapsed" className="text-white font-semibold seek-time-val">
                  {formatClock(position)}
                </span>
                <span>/</span>
                <span
                  id="timeTotal"
                  className="seek-time-val cursor-pointer hover:text-white transition"
                  title="Click to toggle remaining time"
                  onClick={toggleRemainingTime}
                >
                  {showRemainingTime
                    ? `-${formatClock(Math.max(0, (duration || info.duration || 0) - position))}`
                    : formatClock(duration || info.duration || 0)}
                </span>
                <span id="time" hidden>
                  {formatClock(position)} / {formatClock(duration || info.duration || 0)}
                </span>
              </div>
            </div>

            <div className="flex items-center gap-2 sm:gap-3">
              {/* Volume & Mute */}
              <div className="flex items-center gap-1.5 group/vol">
                <button
                  id="mute"
                  type="button"
                  onClick={toggleMute}
                  title="Mute (m)"
                  className="flex h-8 w-8 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/80 hover:bg-white/10 hover:text-white transition"
                >
                  {muted || volume === 0 ? (
                    <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                      <path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51C20.63 14.91 21 13.5 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06c1.38-.31 2.63-.95 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z" />
                    </svg>
                  ) : volume < 0.5 ? (
                    <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                      <path d="M18.5 12c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM5 9v6h4l5 5V4L9 9H5z" />
                    </svg>
                  ) : (
                    <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                      <path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z" />
                    </svg>
                  )}
                </button>
                <input
                  id="volume"
                  type="range"
                  min={0}
                  max={1}
                  step={0.05}
                  value={muted ? 0 : volume}
                  onChange={(e) => handleVolumeChange(Number(e.target.value))}
                  aria-label="Volume"
                  className="w-16 sm:w-20 h-1 bg-white/20 rounded-lg appearance-none cursor-pointer accent-brand-500"
                />
              </div>

              {/* Playback Speed */}
              <select
                id="speed"
                value={speed}
                onChange={(e) => handleSpeedChange(Number(e.target.value))}
                title="Speed (< / >)"
                aria-label="Playback speed"
                className="rounded-full border border-white/15 bg-obsidian-850 px-2.5 py-1 text-xs font-semibold text-white/80 hover:bg-obsidian-800 transition focus:outline-none focus:ring-1 focus:ring-brand-500"
              >
                <option value="0.75">.75×</option>
                <option value="1">1×</option>
                <option value="1.25">1.25×</option>
                <option value="1.5">1.5×</option>
                <option value="2">2×</option>
              </select>

              {/* Subtitles & Settings Pill */}
              <span
                id="ccMergedPill"
                className="cc-merged-pill"
                title="Subtitles & Settings (c)"
              >
                <button
                  id="ccBtn"
                  type="button"
                  className={activeTrackIndex >= 0 ? 'active' : ''}
                  onClick={(e) => {
                    e.stopPropagation();
                    toggleCC();
                  }}
                  title="Toggle subtitles (c)"
                >
                  CC
                </button>
                <span className="cc-sep" />
                <button
                  id="subSettingsBtn"
                  type="button"
                  className={isSubModalOpen ? 'active' : ''}
                  onClick={(e) => {
                    e.stopPropagation();
                    setIsSubModalOpen((prev) => !prev);
                  }}
                  title="Subtitle settings"
                  aria-label="Subtitle settings"
                >
                  ⚙
                </button>
              </span>

              {/* Aspect Ratio */}
              <button
                id="aspectBtn"
                type="button"
                onClick={nextAspect}
                title="Aspect ratio (a)"
                aria-label="Aspect ratio"
                className="flex h-8 w-8 sm:h-9 sm:w-9 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/80 transition hover:bg-white/10 hover:text-white"
              >
                <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                  <path d="M19 12h-2v3h-3v2h5v-5zM7 9h3V7H5v5h2V9zm14-6H3c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 16.01H3V4.99h18v14.02z" />
                </svg>
              </button>

              {/* Rotate Screen */}
              <button
                id="rotateBtn"
                type="button"
                onClick={toggleRotation}
                title="Rotate screen (r)"
                aria-label="Rotate screen"
                className="flex h-8 w-8 sm:h-9 sm:w-9 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/80 transition hover:bg-white/10 hover:text-white"
              >
                <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                  <path d="M16.48 2.52c3.27 1.55 5.61 4.72 5.97 8.48h1.5C23.44 4.84 18.29 0 12 0l-.66.03 3.81 3.81 1.33-1.32zm-6.25-.77c-.59-.59-1.54-.59-2.12 0L1.75 8.11c-.59.59-.59 1.54 0 2.12l12.02 12.02c.59.59 1.54.59 2.12 0l6.36-6.36c.59-.59.59-1.54 0-2.12L10.23 1.75zm4.6 19.44L2.81 9.17l6.36-6.36 12.02 12.02-6.36 6.36zm-7.31.29C4.25 19.93 1.91 16.76 1.55 13H.05C.56 19.16 5.71 24 12 24l.66-.03-3.81-3.81-1.33 1.32z" />
                </svg>
              </button>

              {/* Picture-in-Picture */}
              <button
                id="pipBtn"
                type="button"
                onClick={togglePip}
                title="Picture-in-Picture (p / i)"
                aria-label="Picture-in-Picture"
                className={`flex h-8 w-8 sm:h-9 sm:w-9 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/80 transition hover:bg-white/10 hover:text-white ${
                  isPipActive ? 'active' : ''
                }`}
              >
                <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                  <path d="M19 7h-8v6h8V7zm2-4H3c-1.1 0-2 .9-2 2v14c0 1.1.9 1.98 2 1.98h18c1.1 0 2-.88 2-1.98V5c0-1.1-.9-2-2-2zm0 16.01H3V4.98h18v14.03z" />
                </svg>
              </button>

              {/* Cast to Smart TV / Chromecast */}
              <button
                id="castBtn"
                type="button"
                onClick={() => {
                  setCastModalOpen(true);
                  resetControlsTimer();
                }}
                disabled={!isPlaybackReady}
                title="Cast to Smart TV / Chromecast"
                aria-label="Cast to Smart TV or Chromecast"
                className={`flex h-8 w-8 sm:h-9 sm:w-9 items-center justify-center rounded-full border transition ${
                  activeCastDevice
                    ? 'border-brand-500/50 bg-brand-500/20 text-brand-400'
                    : 'border-white/15 bg-white/5 text-white/80 hover:bg-white/10 hover:text-white'
                } disabled:opacity-40`}
              >
                <Icon name="cast" size={16} />
              </button>

              {/* Stats for Nerds */}
              <button
                id="nerdStatsBtn"
                type="button"
                onClick={() => {
                  setIsNerdStatsOpen((prev) => !prev);
                  resetControlsTimer();
                }}
                title="Stats for nerds (n)"
                aria-label="Stats for nerds"
                className={`flex h-8 w-8 sm:h-9 sm:w-9 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/80 transition hover:bg-white/10 hover:text-white ${
                  isNerdStatsOpen ? 'active' : ''
                }`}
              >
                <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                  <path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zM9 17H7v-5h2v5zm4 0h-2v-9h2v9zm4 0h-2v-4h2v4z" />
                </svg>
              </button>

              {/* Keyboard Shortcuts */}
              <button
                id="shortcutsBtn"
                type="button"
                onClick={() => {
                  setIsShortcutsOpen((prev) => !prev);
                  resetControlsTimer();
                }}
                title="Keyboard Shortcuts (?)"
                aria-label="Keyboard Shortcuts"
                className={`flex h-8 w-8 sm:h-9 sm:w-9 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/80 transition hover:bg-white/10 hover:text-white ${
                  isShortcutsOpen ? 'active' : ''
                }`}
              >
                <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                  <path d="M20 5H4c-1.1 0-1.99.9-1.99 2L2 17c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm-9 3h2v2h-2V8zm0 3h2v2h-2v-2zM8 8h2v2H8V8zm0 3h2v2H8v-2zm-1 2H5v-2h2v2zm0-3H5V8h2v2zm9 7H8v-2h8v2zm0-4h-2v-2h2v2zm0-3h-2V8h2v2zm3 3h-2v-2h2v2zm0-3h-2V8h2v2z" />
                </svg>
              </button>

              {/* Fullscreen button */}
              <button
                id="full"
                type="button"
                onClick={toggleFullscreen}
                disabled={!ready}
                title="Fullscreen (f)"
                className="flex h-8 w-8 sm:h-9 sm:w-9 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/70 hover:bg-white/10 hover:text-white transition disabled:opacity-30"
              >
                <Icon name="ruler" size={14} />
              </button>
            </div>
          </div>
        </div>

        {/* Subtitle Settings Modal */}
        <SubtitleSettingsModal
          isOpen={isSubModalOpen}
          onClose={() => setIsSubModalOpen(false)}
          tracks={tracks}
          activeTrackIndex={activeTrackIndex}
          onSelectTrack={selectTrack}
          prefs={subPrefs}
          onUpdatePref={updateSubPref}
          onUploadSubtitle={uploadSubtitle}
        />

        {/* Nerd Stats HUD */}
        <NerdStatsHud
          isOpen={isNerdStatsOpen}
          onClose={() => setIsNerdStatsOpen(false)}
          videoRef={videoRef}
          filename={decoded}
          mode={mode}
          directPlay={directPlay}
          isTranscodeReady={info.is_transcode_ready}
          transcodePercent={transcode?.percent}
        />

        {/* Shortcuts Modal */}
        <ShortcutsModal
          isOpen={isShortcutsOpen}
          onClose={() => setIsShortcutsOpen(false)}
        />

        {/* Cast Picker Modal */}
        <CastModal
          open={castModalOpen}
          onClose={() => setCastModalOpen(false)}
          onSelectDevice={handleSelectCastDevice}
          onDisconnectDevice={handleDisconnectCast}
          activeDeviceId={activeCastDevice?.id}
          connectingDeviceId={connectingCastDeviceId}
        />
      </div>

      {/* Main Transcode Progress Card */}
      <TranscodeCard
        transcode={transcode}
        isReady={info.is_transcode_ready}
        needsTranscode={mode === 'hls' && !info.is_transcode_ready}
      />
    </div>
  );
}

export default PlayerPage;