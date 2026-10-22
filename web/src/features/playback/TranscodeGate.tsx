import type { TranscodeStatusResponse } from '../../lib/api/types';
import { Icon } from '../../components/icons';

export interface TranscodeGateProps {
  filename: string;
  transcode: TranscodeStatusResponse | null | undefined;
  onRefresh?: () => void;
  onQueuePreTranscode?: () => Promise<void> | void;
  diagnosticReason?: string;
}

function formatClock(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return 'calculating...';
  const total = Math.floor(seconds);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
}

export function TranscodeGate({
  filename,
  transcode,
  onRefresh,
  onQueuePreTranscode,
  diagnosticReason,
}: TranscodeGateProps) {
  const percent = Math.min(100, Math.max(0, transcode?.percent ?? 0));
  const speed = transcode?.speed ?? 0;
  const remaining = transcode?.remaining ?? 0;
  const title = filename.split('/').pop()?.replace(/\.[^/.]+$/, '') ?? filename;

  const isActive =
    transcode?.status === 'building' || (transcode?.percent != null && transcode.percent > 0);
  const isPartial = transcode?.status === 'partial';

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
        <span>
          {isActive
            ? 'Dual AMD GPU Transcoder Active (RX 560X + Vega 8)'
            : isPartial
              ? 'Transcode Incomplete (Partial)'
              : 'Pre-Transcode Required'}
        </span>
      </div>

      <h2 className="relative text-xl sm:text-2xl font-bold tracking-tight text-white mb-2 max-w-lg">
        {isActive
          ? `Building a transcode for '${title}'`
          : isPartial
            ? `Transcode incomplete for '${title}'`
            : `Pre-transcode required for '${title}'`}
      </h2>

      <p className="relative text-xs sm:text-sm text-white/60 max-w-md mb-6 leading-relaxed">
        {isActive
          ? 'This media requires hardware transcoding. To guarantee full timeline seeking, zero audio drift, and glitch-free playback, media must reach 100% completion before starting.'
          : isPartial
            ? 'A previous transcode stopped before reaching 100% completion. Pre-transcoding must reach 100% to guarantee full timeline seeking and prevent audio drift.'
            : diagnosticReason ||
              'This media format cannot be decoded natively by this browser. Pre-transcoding is required before playback can begin to guarantee smooth, glitch-free streaming.'}
      </p>

      {/* Progress Bar & Numerical HUD (Shown when active) */}
      {isActive && (
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
      )}

      {/* Action / Refresh controls */}
      <div className="relative flex flex-col items-center gap-3 text-xs text-white/40 mt-1">
        {isActive ? (
          <div className="flex items-center gap-2">
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
        ) : (
          onQueuePreTranscode && (
            <button
              type="button"
              data-testid="queue-pre-transcode-btn"
              onClick={onQueuePreTranscode}
              className="inline-flex items-center gap-2 rounded-xl bg-brand-600 px-5 py-2.5 text-xs sm:text-sm font-semibold text-white shadow-lg shadow-brand-600/30 transition hover:bg-brand-500 active:scale-95"
            >
              <Icon name="bolt" size={15} />
              <span>Queue Baseline Pre-Transcode</span>
            </button>
          )
        )}
      </div>
    </div>
  );
}
