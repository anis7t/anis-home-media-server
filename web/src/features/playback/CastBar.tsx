import { useState } from 'react';
import { Icon } from '../../components/icons';
import type { CastDevice, CastStatusResponse } from '../../lib/api/cast';

export interface CastBarProps {
  device: CastDevice;
  filename: string;
  status: CastStatusResponse | null;
  onControl: (
    action: 'play' | 'pause' | 'stop' | 'seek' | 'volume' | 'mute' | 'subtitle',
    value?: number | boolean,
  ) => void;
  onDisconnect: () => void;
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

export function CastBar({
  device,
  filename,
  status,
  onControl,
  onDisconnect,
}: CastBarProps) {
  const isPlaying = status?.state === 'playing';
  const position = status?.position ?? 0;
  const duration = status?.duration ?? 0;
  const volume = status?.volume ?? 100;
  const isMuted = status?.muted ?? false;
  const subtitles = status?.subtitles ?? [];
  const activeSubId = status?.active_subtitle_id ?? 0;

  const [scrubPosition, setScrubPosition] = useState<number | null>(null);
  const [scrubVolume, setScrubVolume] = useState<number | null>(null);
  const [showSubMenu, setShowSubMenu] = useState(false);

  const displayPos = scrubPosition !== null ? scrubPosition : position;
  const displayPct = duration > 0 ? Math.min(100, Math.max(0, (displayPos / duration) * 100)) : 0;

  const displayVolume = scrubVolume !== null ? scrubVolume : volume;
  const effectiveVolume = isMuted ? 0 : displayVolume;

  const title = filename.split('/').pop()?.replace(/\.[^/.]+$/, '') ?? filename;

  return (
    <div
      id="castBar"
      className="relative aspect-video w-full rounded-2xl sm:rounded-3xl bg-neutral-950/95 ring-1 ring-white/10 shadow-2xl flex flex-col justify-between p-6 sm:p-10 text-white overflow-hidden"
      role="region"
      aria-label="Active Cast Remote Controller"
    >
      {/* Ambient OTT glow */}
      <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
        <div className="h-72 w-72 rounded-full bg-brand-600/20 blur-3xl animate-pulse" />
      </div>

      {/* Top bar: Connected Target Device & Disconnect */}
      <div className="relative z-10 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-brand-500/15 text-brand-400 border border-brand-500/30 shadow-lg">
            <Icon name={device.kind === 'cast' ? 'cast' : 'tv'} size={20} />
          </span>
          <div>
            <div className="flex items-center gap-2">
              <span className="text-xs font-semibold uppercase tracking-wider text-brand-400 font-mono">
                Casting Active
              </span>
              <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase font-mono ${
                isPlaying
                  ? 'bg-emerald-500/15 text-emerald-400 border border-emerald-500/30'
                  : 'bg-amber-500/15 text-amber-400 border border-amber-500/30'
              }`}>
                <span className={`h-1.5 w-1.5 rounded-full ${isPlaying ? 'bg-emerald-400 animate-pulse' : 'bg-amber-400'}`} />
                {status?.state ?? 'connecting'}
              </span>
            </div>
            <h3 className="text-base sm:text-lg font-bold tracking-tight text-white mt-0.5 truncate max-w-xs sm:max-w-md">
              {device.name}
            </h3>
          </div>
        </div>

        <button
          type="button"
          id="castDisconnectBtn"
          onClick={onDisconnect}
          aria-label="Disconnect cast"
          title="Disconnect cast and return to local screen"
          className="flex items-center gap-2 rounded-full border border-rose-500/30 bg-rose-500/10 px-3.5 py-1.5 text-xs font-semibold text-rose-300 shadow-sm transition hover:bg-rose-500/20 active:scale-95"
        >
          <span>✕</span>
          <span>Disconnect</span>
        </button>
      </div>

      {/* Center Hero: Cast Status & Media Title */}
      <div className="relative z-10 my-auto text-center py-6">
        <div className="mx-auto mb-4 flex h-20 w-20 items-center justify-center rounded-full bg-white/5 border border-white/10 ring-8 ring-white/5">
          <Icon name={device.kind === 'cast' ? 'cast' : 'tv'} size={36} className="text-white/80 animate-pulse" />
        </div>
        <h2 className="text-xl sm:text-2xl font-bold tracking-tight text-white mb-1.5 truncate max-w-lg mx-auto">
          {title}
        </h2>
        <p className="text-xs sm:text-sm text-white/50 max-w-md mx-auto">
          Playing on {device.name} • Controlled from Media Server
        </p>
      </div>

      {/* Bottom Remote Transport Bar */}
      <div className="relative z-10 space-y-3">
        {/* Timeline Slider & Time HUD */}
        <div className="space-y-1.5">
          <div className="flex items-center justify-between text-xs font-mono text-white/70">
            <span>{formatClock(displayPos)}</span>
            <span>{formatClock(duration)}</span>
          </div>

          <div className="relative h-2 w-full rounded-full bg-white/10 flex items-center">
            <div
              className="h-full rounded-full brand-gradient brand-glow"
              style={{ width: `${displayPct}%` }}
            />
            <input
              type="range"
              min={0}
              max={duration || 100}
              step={1}
              value={displayPos}
              onChange={(e) => setScrubPosition(Number(e.target.value))}
              onMouseUp={(e) => {
                const targetSec = Number((e.target as HTMLInputElement).value);
                onControl('seek', targetSec);
                setScrubPosition(null);
              }}
              onTouchEnd={(e) => {
                const targetSec = Number((e.target as HTMLInputElement).value);
                onControl('seek', targetSec);
                setScrubPosition(null);
              }}
              aria-label="Remote timeline scrubber"
              className="absolute inset-0 w-full opacity-0 cursor-pointer h-full"
            />
          </div>
        </div>

        {/* Transport Controls Row */}
        <div className="flex items-center justify-between pt-1">
          <div className="flex items-center gap-2 sm:gap-3">
            {/* Rewind 10s */}
            <button
              type="button"
              onClick={() => onControl('seek', Math.max(0, position - 10))}
              aria-label="Seek back 10s"
              title="Seek back 10s"
              className="flex h-9 w-9 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/80 transition hover:bg-white/10 hover:text-white"
            >
              <span className="text-xs font-bold font-mono">-10</span>
            </button>

            {/* Remote Play / Pause */}
            <button
              type="button"
              id="castPlayPauseBtn"
              onClick={() => onControl(isPlaying ? 'pause' : 'play')}
              aria-label={isPlaying ? 'Pause' : 'Play'}
              title={isPlaying ? 'Pause' : 'Play'}
              className="brand-gradient brand-glow-sm flex h-11 w-11 items-center justify-center rounded-full text-white shadow-md transition hover:scale-105 active:scale-95"
            >
              {isPlaying ? (
                <span className="text-base font-bold">⏸</span>
              ) : (
                <Icon name="play" size={17} className="ml-0.5 text-white" />
              )}
            </button>

            {/* Fast-Forward 10s */}
            <button
              type="button"
              onClick={() => onControl('seek', Math.min(duration, position + 10))}
              aria-label="Seek forward 10s"
              title="Seek forward 10s"
              className="flex h-9 w-9 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/80 transition hover:bg-white/10 hover:text-white"
            >
              <span className="text-xs font-bold font-mono">+10</span>
            </button>

            {/* Subtitle Selector */}
            {subtitles.length > 0 && (
              <div className="relative">
                <button
                  type="button"
                  id="castSubBtn"
                  onClick={() => setShowSubMenu((prev) => !prev)}
                  aria-label="Cast subtitles"
                  title="Cast subtitles"
                  className={`flex h-9 w-9 sm:h-10 sm:w-10 items-center justify-center rounded-full border shadow-md backdrop-blur-md transition-all duration-200 hover:scale-105 active:scale-95 ${
                    activeSubId > 0
                      ? 'border-brand-500/60 bg-brand-500/20 text-brand-400'
                      : 'border-white/20 bg-black/60 text-white/90 hover:border-white/40 hover:bg-black/80 hover:text-white'
                  }`}
                >
                  <span className="text-xs font-bold font-mono tracking-tighter">CC</span>
                </button>

                {showSubMenu && (
                  <>
                    <div
                      className="fixed inset-0 z-40"
                      onClick={() => setShowSubMenu(false)}
                    />
                    <div
                      id="castSubMenu"
                      className="absolute bottom-full left-0 mb-2 z-50 min-w-[220px] sm:min-w-[260px] max-h-56 sm:max-h-72 overflow-y-auto overflow-x-hidden rounded-2xl border border-white/20 bg-neutral-900/95 p-1.5 shadow-2xl backdrop-blur-xl animate-in fade-in zoom-in-95 duration-150 custom-scrollbar"
                      role="menu"
                      aria-label="Cast Subtitles"
                    >
                      <div className="sticky top-0 z-10 bg-neutral-900/95 backdrop-blur-md px-3 py-1.5 text-[11px] font-bold uppercase tracking-wider text-white/50 border-b border-white/10 mb-1 flex items-center justify-between">
                        <span>Subtitles</span>
                        <span className="font-mono text-[10px] text-white/40">{subtitles.length} tracks</span>
                      </div>
                      <button
                        type="button"
                        role="menuitem"
                        onClick={() => {
                          onControl('subtitle', 0);
                          setShowSubMenu(false);
                        }}
                        className={`w-full flex items-center justify-between rounded-xl px-3 py-1.5 text-xs font-medium transition ${
                          activeSubId === 0
                            ? 'bg-brand-500/20 text-brand-400 font-semibold'
                            : 'text-white/80 hover:bg-white/10 hover:text-white'
                        }`}
                      >
                        <span>Off</span>
                        {activeSubId === 0 && <span className="text-brand-400">✓</span>}
                      </button>
                      {subtitles.map((track) => (
                        <button
                          key={track.track_id}
                          type="button"
                          role="menuitem"
                          onClick={() => {
                            onControl('subtitle', track.track_id);
                            setShowSubMenu(false);
                          }}
                          className={`w-full flex items-center justify-between rounded-xl px-3 py-1.5 text-xs font-medium transition ${
                            activeSubId === track.track_id
                              ? 'bg-brand-500/20 text-brand-400 font-semibold'
                              : 'text-white/80 hover:bg-white/10 hover:text-white'
                          }`}
                        >
                          <span className="truncate pr-2">{track.label || `Track ${track.track_id}`}</span>
                          {activeSubId === track.track_id && <span className="text-brand-400">✓</span>}
                        </button>
                      ))}
                    </div>
                  </>
                )}
              </div>
            )}
          </div>

          {/* Volume Control */}
          <div className="flex items-center gap-2 group/castvol">
            <button
              id="castMuteBtn"
              type="button"
              onClick={() => onControl('mute', !isMuted)}
              title={isMuted ? 'Unmute' : 'Mute'}
              aria-label={isMuted ? 'Unmute' : 'Mute'}
              className="flex h-9 w-9 sm:h-10 sm:w-10 items-center justify-center rounded-full border border-white/20 bg-black/60 text-white/90 shadow-md backdrop-blur-md transition-all duration-200 hover:scale-105 hover:border-white/40 hover:bg-black/80 hover:text-white active:scale-95"
            >
              {isMuted || effectiveVolume === 0 ? (
                <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor">
                  <path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51C20.63 14.91 21 13.5 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06c1.38-.31 2.63-.95 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z" />
                </svg>
              ) : effectiveVolume < 50 ? (
                <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor">
                  <path d="M18.5 12c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM5 9v6h4l5 5V4L9 9H5z" />
                </svg>
              ) : (
                <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor">
                  <path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z" />
                </svg>
              )}
            </button>
            <input
              id="castVolume"
              type="range"
              min={0}
              max={100}
              step={1}
              value={effectiveVolume}
              onChange={(e) => {
                const val = Number(e.target.value);
                setScrubVolume(val);
                onControl('volume', val);
              }}
              onMouseUp={() => setScrubVolume(null)}
              onTouchEnd={() => setScrubVolume(null)}
              aria-label="Remote volume"
              style={{
                background: `linear-gradient(to right, #e50914 0%, #e50914 ${Math.round(effectiveVolume)}%, rgba(255,255,255,0.25) ${Math.round(effectiveVolume)}%, rgba(255,255,255,0.25) 100%)`,
              }}
              className="w-16 sm:w-28 h-1.5 rounded-full appearance-none cursor-pointer accent-brand-500 transition-all"
            />
            <span
              id="castVolumePercent"
              className="font-mono text-xs font-semibold text-white/90 min-w-[34px] select-none text-left"
            >
              {Math.round(effectiveVolume)}%
            </span>
          </div>
        </div>
      </div>
    </div>
  );
}
