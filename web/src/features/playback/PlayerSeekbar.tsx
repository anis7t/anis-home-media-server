import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

interface PreviewMeta {
  duration: number;
  interval: number;
  count: number;
  base_url: string;
}

interface BufferSegment {
  left: number;
  width: number;
}

export interface PlayerSeekbarProps {
  filename: string;
  duration: number;
  currentTime: number;
  buffered?: { start: number; end: number }[] | null;
  onSeek: (seconds: number) => void;
  onScrubbingChange?: (isScrubbing: boolean) => void;
  disabled?: boolean;
  canPreview?: boolean;
}

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

export function PlayerSeekbar({
  filename,
  duration,
  currentTime,
  buffered,
  onSeek,
  onScrubbingChange,
  disabled = false,
  canPreview = true,
}: PlayerSeekbarProps) {
  const trackRef = useRef<HTMLDivElement | null>(null);

  const [previewMeta, setPreviewMeta] = useState<PreviewMeta | null>(null);
  const [hoverPct, setHoverPct] = useState(0);
  const [hoverSeconds, setHoverSeconds] = useState(0);
  const [previewClampedX, setPreviewClampedX] = useState(0);
  const [hoverActive, setHoverActive] = useState(false);
  const [isScrubbing, setIsScrubbing] = useState(false);
  const [scrubPct, setScrubPct] = useState<number | null>(null);

  // Thumbnail loading state
  const [previewImgUrl, setPreviewImgUrl] = useState('');
  const [previewImgLoaded, setPreviewImgLoaded] = useState(false);
  const [previewImgError, setPreviewImgError] = useState(false);

  // Load seek preview metadata only when canPreview is true
  useEffect(() => {
    if (!filename || !canPreview) {
      setPreviewMeta(null);
      return;
    }
    const controller = new AbortController();
    const encoded = filename.split('/').map(encodeURIComponent).join('/');

    fetch(`/api/seek-preview-meta/${encoded}`, { signal: controller.signal })
      .then((res) => (res.ok ? res.json() : null))
      .then((data: PreviewMeta | null) => {
        if (data && data.count && data.interval) {
          setPreviewMeta(data);
        }
      })
      .catch(() => {
        // Preview metadata optional / non-fatal
      });

    return () => controller.abort();
  }, [filename, canPreview]);

  // Compute buffered bars
  const bufferSegments = useMemo<BufferSegment[]>(() => {
    if (!buffered || !duration || duration <= 0) return [];
    return buffered
      .filter((b) => b.end > b.start)
      .map((b) => {
        const left = Math.max(0, Math.min(100, (b.start / duration) * 100));
        const right = Math.max(0, Math.min(100, (b.end / duration) * 100));
        return {
          left,
          width: Math.max(0, right - left),
        };
      });
  }, [buffered, duration]);

  // Played percentage (driven by scrub if dragging, else currentTime)
  const playedPct = useMemo(() => {
    if (scrubPct !== null) return scrubPct;
    if (!duration || duration <= 0) return 0;
    return Math.max(0, Math.min(100, (currentTime / duration) * 100));
  }, [scrubPct, currentTime, duration]);

  // Update preview thumbnail when hoverSeconds changes
  const updateThumbnail = useCallback(
    (targetSec: number) => {
      if (!previewMeta || !previewMeta.count || !previewMeta.interval || !filename || !canPreview) {
        setPreviewImgUrl('');
        setPreviewImgLoaded(false);
        setPreviewImgError(false);
        return;
      }

      const idx = Math.max(
        0,
        Math.min(previewMeta.count - 1, Math.floor(targetSec / previewMeta.interval)),
      );
      const thumbName = `thumb_${String(idx).padStart(5, '0')}.jpg`;
      const encoded = filename.split('/').map(encodeURIComponent).join('/');
      const url = `/seek-preview/${encoded}/${thumbName}`;

      setPreviewImgUrl((prev) => {
        if (prev === url) return prev;
        setPreviewImgLoaded(false);
        setPreviewImgError(false);
        return url;
      });
    },
    [previewMeta, filename, canPreview],
  );

  const calculateHover = useCallback(
    (clientX: number) => {
      const track = trackRef.current;
      if (!track) return;
      const rect = track.getBoundingClientRect();
      const rawPct = Math.max(0, Math.min(1, (clientX - rect.left) / Math.max(rect.width, 1)));
      const pct = rawPct * 100;
      const targetSec = rawPct * (duration || 0);

      setHoverPct(pct);
      setHoverSeconds(targetSec);

      // Edge clamping for preview box (220px width desktop, 180px mobile)
      const isMobile = window.innerWidth <= 768;
      const previewWidth = isMobile ? 180 : 220;
      const halfWidth = previewWidth / 2;
      const pointerX = clientX - rect.left;
      const clamped = Math.max(halfWidth + 4, Math.min(rect.width - halfWidth - 4, pointerX));
      setPreviewClampedX(clamped);

      updateThumbnail(targetSec);
    },
    [duration, updateThumbnail],
  );

  const handleMouseMove = (e: React.MouseEvent<HTMLDivElement>) => {
    if (disabled) return;
    setHoverActive(true);
    calculateHover(e.clientX);
  };

  const handleMouseEnter = (e: React.MouseEvent<HTMLDivElement>) => {
    if (disabled) return;
    setHoverActive(true);
    calculateHover(e.clientX);
  };

  const handleMouseLeave = () => {
    if (!isScrubbing) {
      setHoverActive(false);
    }
  };

  const handlePointerDown = (e: React.PointerEvent<HTMLInputElement>) => {
    if (disabled) return;
    setIsScrubbing(true);
    setHoverActive(true);
    onScrubbingChange?.(true);
    calculateHover(e.clientX);
    const track = trackRef.current;
    if (track) {
      const rect = track.getBoundingClientRect();
      const pct = Math.max(0, Math.min(100, ((e.clientX - rect.left) / rect.width) * 100));
      setScrubPct(pct);
    }
  };

  const handlePointerMove = (e: React.PointerEvent<HTMLInputElement>) => {
    if (isScrubbing) {
      calculateHover(e.clientX);
    }
  };

  const handleTouchMove = (e: React.TouchEvent<HTMLInputElement>) => {
    if (isScrubbing && e.touches[0]) {
      calculateHover(e.touches[0].clientX);
    }
  };

  const handleInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const pct = Number(e.target.value);
    setScrubPct(pct);
  };

  const commitSeek = (pctVal: number) => {
    setIsScrubbing(false);
    setHoverActive(false);
    onScrubbingChange?.(false);
    setScrubPct(null);
    if (duration > 0) {
      const targetSec = (pctVal / 100) * duration;
      onSeek(targetSec);
    }
  };

  const handlePointerUp = (e: React.PointerEvent<HTMLInputElement>) => {
    commitSeek(Number((e.target as HTMLInputElement).value));
  };

  const handleKeyUp = (e: React.KeyboardEvent<HTMLInputElement>) => {
    commitSeek(Number((e.target as HTMLInputElement).value));
  };

  const isPreviewShowing = Boolean(canPreview && !disabled && (hoverActive || isScrubbing) && duration > 0);

  return (
    <div
      id="seekTrack"
      ref={trackRef}
      className={`seek-track ${isScrubbing ? 'is-scrubbing' : ''}`}
      role="presentation"
      onMouseMove={handleMouseMove}
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
    >
      <span className="seek-rail" aria-hidden="true" />
      <span id="seekBuffered" className="seek-buffered" aria-hidden="true">
        {bufferSegments.map((seg, i) => (
          <i key={i} style={{ left: `${seg.left}%`, width: `${seg.width}%` }} />
        ))}
      </span>
      <span id="seekPlayed" className="seek-played" style={{ width: `${playedPct}%` }} aria-hidden="true" />
      <span
        id="seekHoverMarker"
        className="seek-hover-marker"
        style={{ left: `${hoverPct}%`, opacity: hoverActive && canPreview ? 1 : 0 }}
        aria-hidden="true"
      />
      <span id="seekThumb" className="seek-thumb" style={{ left: `${playedPct}%` }} aria-hidden="true" />

      {/* Floating Seek Hover & Scrub Preview Card */}
      {canPreview && !disabled && (
        <div
          id="seekPreview"
          className="seek-preview"
          style={{
            left: `${previewClampedX}px`,
            display: isPreviewShowing ? 'block' : 'none',
            visibility: isPreviewShowing ? 'visible' : 'hidden',
            opacity: isPreviewShowing ? 1 : 0,
          }}
          hidden={!isPreviewShowing}
        >
          {previewImgUrl && !previewImgError ? (
            <img
              className="seek-preview-image"
              src={previewImgUrl}
              alt=""
              decoding="async"
              style={{ display: previewImgLoaded ? 'block' : 'none' }}
              onLoad={() => setPreviewImgLoaded(true)}
              onError={() => setPreviewImgError(true)}
            />
          ) : null}

          {(!previewImgLoaded || previewImgError || !previewImgUrl) && (
            <div className="seek-preview-spinner-wrap" role="status" aria-label="Loading preview">
              {previewImgError ? (
                <span className="seek-preview-fallback">Frame unavailable</span>
              ) : (
                <span className="seek-preview-spinner" />
              )}
            </div>
          )}

          <div className="seek-preview-time">{formatClock(hoverSeconds)}</div>
        </div>
      )}

      <div id="seekTooltip" className="seek-tooltip" hidden style={{ left: `${hoverPct}%` }}>
        {formatClock(hoverSeconds)}
      </div>

      <input
        id="seek"
        type="range"
        min={0}
        max={100}
        step="any"
        value={playedPct}
        onChange={handleInputChange}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onTouchMove={handleTouchMove}
        onPointerUp={handlePointerUp}
        onKeyUp={handleKeyUp}
        onTouchEnd={(e) => commitSeek(Number((e.target as HTMLInputElement).value))}
        disabled={disabled}
        aria-label="Seek"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={Number(playedPct.toFixed(2))}
      />
    </div>
  );
}
