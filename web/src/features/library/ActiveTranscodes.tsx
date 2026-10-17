import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';

export interface ActiveTranscode {
  filename: string;
  title: string;
  year?: number | null;
  poster_url?: string | null;
  mode: string;
  status: string;
  percent: number;
  speed?: string | null;
  encoded_str?: string;
  duration_str?: string;
  eta_str?: string;
}

function formatEta(seconds: number): string {
  if (!seconds || seconds <= 0) return '0s';
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  if (m >= 60) {
    const h = Math.floor(m / 60);
    const remM = m % 60;
    return `${h}h ${remM}m`;
  }
  return `${m}m ${s}s`;
}

export interface ActiveTranscodesProps {
  readonly onActiveChange?: (hasActive: boolean) => void;
}

export function ActiveTranscodes({ onActiveChange }: ActiveTranscodesProps = {}) {
  const [items, setItems] = useState<ActiveTranscode[]>([]);

  useEffect(() => {
    onActiveChange?.(items.length > 0);
  }, [items.length, onActiveChange]);

  useEffect(() => {
    let mounted = true;

    const poll = async () => {
      try {
        // Try /api/transcodes first (standard media server endpoint)
        const res = await fetch('/api/transcodes');
        if (res.ok) {
          const data = await res.json();
          if (mounted && Array.isArray(data.transcodes)) {
            setItems(data.transcodes);
            return;
          }
        }
      } catch {
        // Fall back to /api/transcode/jobs if /api/transcodes is not yet mirrored
      }

      try {
        const res = await fetch('/api/transcode/jobs');
        if (res.ok) {
          const data = await res.json();
          if (mounted && Array.isArray(data.jobs)) {
            const liveJobs = data.jobs.filter(
              (j: any) => j.status === 'running' || j.status === 'queued'
            );
            const mapped: ActiveTranscode[] = liveJobs.map((j: any) => {
              const nameParts = j.filename.split('/').pop() || j.filename;
              const cleanTitle = nameParts.replace(/\.[^/.]+$/, '').replace(/\./g, ' ');
              const pct = typeof j.progress === 'number' ? j.progress : 0;
              const spd = j.speed ? `${Number(j.speed).toFixed(1)}x` : undefined;
              const etaSec = typeof j.eta === 'number' ? j.eta : 0;
              return {
                filename: j.filename,
                title: cleanTitle,
                mode: 'HLS Transcode',
                status: j.status,
                percent: pct,
                speed: spd,
                encoded_str: j.encoded_str,
                duration_str: j.duration_str,
                eta_str: etaSec > 0 ? formatEta(etaSec) : 'calculating...',
                poster_url: `/poster/${encodeURIComponent(j.filename)}`,
              };
            });
            setItems(mapped);
          }
        }
      } catch {
        // tolerate network blip
      }
    };

    poll();
    const timer = setInterval(poll, 1500);
    return () => {
      mounted = false;
      clearInterval(timer);
    };
  }, []);

  if (items.length === 0) {
    return null;
  }

  return (
    <section className="relative z-10 space-y-3 pt-2 pb-1" aria-label="Active Hardware Transcodes">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2.5">
          <span className="relative flex h-3 w-3">
            <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-brand-400 opacity-75"></span>
            <span className="relative inline-flex rounded-full h-3 w-3 bg-brand-500"></span>
          </span>
          <h2 className="text-base sm:text-lg font-bold text-white tracking-wide">
            Transcoding &amp; Streams
          </h2>
        </div>
        <span className="rounded-full bg-brand-500/15 border border-brand-500/30 px-3 py-0.5 text-xs font-semibold text-brand-400">
          {items.length} active
        </span>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-3.5">
        {items.map((t) => (
          <Link
            key={t.filename}
            to={`/movie/${encodeURIComponent(t.filename)}`}
            className="group flex gap-3.5 p-3.5 rounded-2xl border border-white/10 bg-obsidian-850 hover:bg-obsidian-800 hover:border-white/20 transition shadow-lg"
          >
            {/* Thumbnail Poster */}
            <div className="w-14 h-20 rounded-lg overflow-hidden bg-obsidian-900 border border-white/10 flex-shrink-0 relative">
              {t.poster_url ? (
                <img
                  src={t.poster_url}
                  alt={t.title}
                  className="w-full h-full object-cover group-hover:scale-105 transition duration-300"
                  loading="lazy"
                  onError={(e) => {
                    // Fallback to placeholder if poster fails
                    (e.target as HTMLElement).style.display = 'none';
                  }}
                />
              ) : null}
              <div className="w-full h-full flex items-center justify-center text-white/30 text-lg select-none">
                🎬
              </div>
            </div>

            {/* Transcode Details & Live Progress */}
            <div className="flex-1 flex flex-col justify-between min-w-0">
              <div>
                <div className="flex items-center justify-between gap-2">
                  <h3 className="text-sm font-bold text-white truncate group-hover:text-brand-400 transition">
                    {t.title}
                  </h3>
                  <span className="text-[10px] font-semibold uppercase tracking-wider px-2 py-0.5 rounded-full bg-brand-500/20 text-brand-300 border border-brand-500/30 flex-shrink-0">
                    {t.mode}
                  </span>
                </div>
                {t.year ? <p className="text-[11px] text-white/40 mt-0.5">{t.year}</p> : null}
              </div>

              {/* Live Progress Bar */}
              <div className="my-1.5">
                <div className="h-2 w-full rounded-full bg-white/10 overflow-hidden relative">
                  <div
                    className="h-full rounded-full bg-gradient-to-r from-brand-600 via-brand-500 to-brand-400 transition-all duration-500"
                    style={{ width: `${Math.min(100, Math.max(0, t.percent))}%` }}
                  />
                </div>
              </div>

              {/* Telemetry Row */}
              <div className="flex items-center justify-between text-[11px] sm:text-xs text-white/60">
                <span className="font-bold text-white tracking-tight">{t.percent.toFixed(1)}%</span>
                {t.speed ? (
                  <span className="text-brand-300 font-semibold">{t.speed}</span>
                ) : null}
                {t.encoded_str && t.duration_str ? (
                  <span className="text-white/50">{t.encoded_str} / {t.duration_str}</span>
                ) : null}
                <span className="font-mono text-white/70">
                  {t.eta_str?.startsWith('ETA:') ? t.eta_str : `ETA: ${t.eta_str}`}
                </span>
              </div>
            </div>
          </Link>
        ))}
      </div>
    </section>
  );
}
