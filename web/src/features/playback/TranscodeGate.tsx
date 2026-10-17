import type { TranscodeStatusResponse } from '../../lib/api/types';
import { Icon } from '../../components/icons';

export interface TranscodeGateProps {
  filename: string;
  transcode: TranscodeStatusResponse | null | undefined;
  onRefresh?: () => void;
}

function formatClock(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return 'calculating...';
  const total = Math.floor(seconds);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
}

export function TranscodeGate({ filename, transcode, onRefresh }: TranscodeGateProps) {
  const percent = Math.min(100, Math.max(0, transcode?.percent ?? 0));
  const speed = transcode?.speed ?? 0;
  const remaining = transcode?.remaining ?? 0;
  const title = filename.split('/').pop()?.replace(/\.[^/.]+$/, '') ?? filename;

  return (
    <div
      id="transcodeGate"
      className="relative aspect-video w-full rounded-2xl sm:rounded-3xl bg-neutral-950/95 ring-1 ring-white/10 shadow-2xl flex flex-col items-center justify-center p-6 sm:p-10 text-center overflow-hidden"
      role="region"
      aria-label="Transcode progress gate"
    >
      {/* Background radial glow */}
      <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
        <div className="h-64 w-64 rounded-full bg-brand-600/15 blur-3xl animate-pulse" />
      </div>

      {/* Hardware Dual-GPU Badge */}
      <div className="relative mb-4 inline-flex items-center gap-2 rounded-full border border-amber-500/30 bg-amber-500/10 px-3 py-1 text-xs font-semibold text-amber-300">
        <Icon name="bolt" size={13} className="text-amber-400" />
        <span>Dual AMD GPU Transcoder Active (RX 560X + Vega 8)</span>
      </div>

      <h2 className="relative text-xl sm:text-2xl font-bold tracking-tight text-white mb-2 max-w-lg">
        Building a transcode for &apos;{title}&apos;
      </h2>

      <p className="relative text-xs sm:text-sm text-white/60 max-w-md mb-6 leading-relaxed">
        This media requires hardware transcoding. To guarantee full timeline seeking, zero audio drift, and glitch-free playback, media must reach 100% completion before starting.
      </p>

      {/* Progress Bar & Numerical HUD */}
      <div className="relative w-full max-w-md mb-3">
        <div className="flex items-center justify-between text-xs font-mono text-white/80 mb-2">
          <span className="flex items-center gap-1.5">
            <span className="h-2 w-2 rounded-full bg-brand-500 animate-ping inline-block" />
            <strong className="text-brand-400 font-semibold">{Math.round(percent)}%</strong>
            <span>transcoded</span>
          </span>
          <span>
            Speed: <strong className="text-white">{speed > 0 ? `${speed.toFixed(1)}×` : 'initializing'}</strong>
          </span>
          <span>
            ETA: <strong className="text-white">{formatClock(remaining)}</strong>
          </span>
        </div>

        <div className="h-2.5 w-full overflow-hidden rounded-full bg-white/10 p-0.5">
          <div
            id="transcodeGateFill"
            className="brand-gradient brand-glow h-full rounded-full transition-all duration-300 ease-out"
            style={{ width: `${percent}%` }}
          />
        </div>
      </div>

      <div className="relative flex items-center gap-2 text-xs text-white/40">
        <span className="animate-spin inline-block">⏳</span>
        <span>Please wait a moment while the server finalizes stream packaging...</span>
        {onRefresh && (
          <button
            type="button"
            onClick={onRefresh}
            className="ml-2 underline text-white/60 hover:text-white transition"
          >
            Check status
          </button>
        )}
      </div>
    </div>
  );
}
