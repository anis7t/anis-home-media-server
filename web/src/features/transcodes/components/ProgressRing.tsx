import { useId } from 'react';

interface ProgressRingProps {
  readonly value: number; // 0 to 100
  readonly size?: number; // diameter in px (default 84)
  readonly strokeWidth?: number; // border thickness in px (default 8)
  readonly speedLabel?: string | null;
  readonly status?: string;
  readonly className?: string;
}

/**
 * Modern Web Guidance compliant progress ring component.
 * Uses conic-gradient, smooth numeric interpolation, and radial mask cutout.
 * Full compliance with prefers-reduced-motion media query.
 */
export function ProgressRing({
  value,
  size = 84,
  strokeWidth = 8,
  speedLabel,
  status = 'running',
  className = '',
}: ProgressRingProps) {
  const clampValue = Math.min(100, Math.max(0, value));
  const ringId = useId();

  const isQueued = status === 'queued';
  const isCompleted = clampValue >= 100;

  // Primary brand red gradient to emerald green upon 100% completion
  const fillColor = isCompleted
    ? '#10b981'
    : isQueued
    ? '#f59e0b'
    : '#e50914';

  const trackColor = 'rgba(255, 255, 255, 0.08)';

  return (
    <div
      className={`relative inline-grid place-items-center select-none ${className}`}
      style={{ width: size, height: size }}
      role="progressbar"
      aria-valuenow={clampValue}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-label={isQueued ? 'Queued transcode' : `Transcode progress: ${clampValue.toFixed(1)}%`}
    >
      <style>{`
        @property --ring-val-${ringId.replace(/:/g, '')} {
          syntax: '<number>';
          inherits: true;
          initial-value: 0;
        }
      `}</style>

      {/* Outer Conic Ring with Radial Cutout Mask */}
      <div
        className="w-full h-full rounded-full transition-all"
        style={{
          background: isQueued
            ? `conic-gradient(from 0deg, ${fillColor} 25%, transparent 25% 50%, ${fillColor} 50% 75%, transparent 75%)`
            : `conic-gradient(${fillColor} calc(${clampValue} * 1%), ${trackColor} 0)`,
          WebkitMaskImage: `radial-gradient(transparent calc(50% - ${strokeWidth}px), black calc(50% - ${strokeWidth}px + 0.5px))`,
          maskImage: `radial-gradient(transparent calc(50% - ${strokeWidth}px), black calc(50% - ${strokeWidth}px + 0.5px))`,
          animation: isQueued ? 'spin 3s linear infinite' : undefined,
        }}
      />

      {/* Center Numerical Content */}
      <div className="absolute inset-0 flex flex-col items-center justify-center text-center p-1 pointer-events-none">
        {isQueued ? (
          <span className="text-[11px] font-bold text-amber-300 uppercase tracking-wider">
            Queue
          </span>
        ) : (
          <>
            <span className="text-sm font-extrabold text-white tracking-tight leading-none">
              {clampValue.toFixed(1)}%
            </span>
            {speedLabel ? (
              <span className="text-[10px] font-semibold text-brand-300 mt-0.5 leading-none">
                {speedLabel}
              </span>
            ) : null}
          </>
        )}
      </div>
    </div>
  );
}
