import { useState } from 'react';
import { Icon } from '../../components/icons';
import type { CastDevice, CastStatusResponse } from '../../lib/api/cast';

export interface CastBarProps {
  device: CastDevice;
  filename: string;
  status: CastStatusResponse | null;
  onControl: (action: 'play' | 'pause' | 'stop' | 'seek' | 'volume', value?: number) => void;
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

  const [scrubPosition, setScrubPosition] = useState<number | null>(null);
  const displayPos = scrubPosition !== null ? scrubPosition : position;
  const displayPct = duration > 0 ? Math.min(100, Math.max(0, (displayPos / duration) * 100)) : 0;

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
          </div>

          {/* Volume Control */}
          <div className="flex items-center gap-2">
            <span className="text-white/60 text-xs">
              <Icon name="speakers" size={15} />
            </span>
            <input
              type="range"
              min={0}
              max={100}
              step={1}
              value={isMuted ? 0 : volume}
              onChange={(e) => onControl('volume', Number(e.target.value))}
              aria-label="Remote volume"
              className="w-20 sm:w-28 accent-brand-500 cursor-pointer"
            />
            <span className="font-mono text-xs text-white/50 w-7 text-right">
              {isMuted ? '0%' : `${Math.round(volume)}%`}
            </span>
          </div>
        </div>
      </div>
    </div>
  );
}
