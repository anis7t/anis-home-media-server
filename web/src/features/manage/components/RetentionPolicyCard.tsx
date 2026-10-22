import { Icon } from '../../../components/icons';
import type { StorageSettings } from '../../../lib/api/manage';

interface RetentionPolicyCardProps {
  readonly settings: StorageSettings | null;
  readonly busy: boolean;
  readonly onUpdatePolicy: (policy: string) => void;
}

const POLICIES = [
  {
    id: 'keep',
    title: 'Keep Both (Default)',
    desc: 'Retains both the raw source video and complete HLS transcode cache indefinitely for zero-latency streaming.',
  },
  {
    id: 'archive',
    title: 'Move to Archive',
    desc: 'Moves raw video files to cold storage (D:\\Flicks\\.archive) while keeping fast SSD HLS stream caches active.',
  },
  {
    id: 'purge_cache',
    title: 'Purge After Watch',
    desc: 'Keeps raw files and clears temporary transcode cache directories once watched to conserve fast SSD headroom.',
  },
] as const;

export function RetentionPolicyCard({
  settings,
  busy,
  onUpdatePolicy,
}: RetentionPolicyCardProps) {
  return (
    <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6">
      <div className="flex items-center gap-2.5">
        <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-brand-500/15 text-brand-400 border border-brand-500/30">
          <Icon name="sparkle" size={18} />
        </div>
        <div>
          <h2 className="text-xl font-bold text-white">Post-Transcode Retention Policy</h2>
          <p className="text-xs text-white/50">
            Controls how raw files and transcode caches are managed after playback
          </p>
        </div>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3.5">
        {POLICIES.map((pol) => {
          const isSelected = settings?.retention_policy === pol.id;
          return (
            <button
              key={pol.id}
              type="button"
              disabled={busy}
              onClick={() => onUpdatePolicy(pol.id)}
              className={`rounded-2xl border p-4.5 text-left transition space-y-2 cursor-pointer ${
                isSelected
                  ? 'border-brand-500/80 bg-brand-500/15 ring-2 ring-brand-500/30'
                  : 'border-white/10 bg-obsidian-900/60 hover:border-white/20 hover:bg-white/[0.04]'
              }`}
            >
              <div className="flex items-center justify-between">
                <span
                  className={`text-xs font-bold uppercase tracking-wider ${
                    isSelected ? 'text-brand-300' : 'text-white/60'
                  }`}
                >
                  {pol.id}
                </span>
                {isSelected ? (
                  <span className="flex h-4 w-4 items-center justify-center rounded-full bg-brand-500 text-[10px] text-white">
                    ✓
                  </span>
                ) : null}
              </div>
              <h3 className="font-bold text-sm text-white">{pol.title}</h3>
              <p className="text-xs text-white/50 leading-relaxed">{pol.desc}</p>
            </button>
          );
        })}
      </div>
    </section>
  );
}
