import { Icon } from '../../../components/icons';
import { formatBytes, type StorageAuditData } from '../../../lib/api/manage';

interface OrphanedCacheAuditProps {
  readonly auditData: StorageAuditData | null;
  readonly busy: boolean;
  readonly onPurgeOrphans: () => void;
}

export function OrphanedCacheAudit({
  auditData,
  busy,
  onPurgeOrphans,
}: OrphanedCacheAuditProps) {
  const orphanedDirs = auditData?.audit.total_orphaned_dirs ?? 0;
  const orphanedBytes = auditData?.audit.total_orphaned_bytes;

  return (
    <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-rose-500/15 text-rose-400 border border-rose-500/30">
            <Icon name="disc" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Orphaned Cache Audit</h2>
            <p className="text-xs text-white/50">
              Identify and reclaim disk space from abandoned transcode folders
            </p>
          </div>
        </div>

        <button
          type="button"
          disabled={busy || orphanedDirs === 0}
          onClick={onPurgeOrphans}
          className="card-ring rounded-full bg-rose-500/20 border border-rose-500/40 px-5 py-2 text-xs font-semibold text-rose-200 hover:bg-rose-500/30 transition disabled:opacity-30 disabled:hover:bg-rose-500/20"
        >
          {busy ? 'Purging…' : 'Purge Orphaned Caches'}
        </button>
      </div>

      <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-5 flex flex-wrap items-center justify-between gap-4 text-xs">
        <div>
          <span className="block text-white/40">Orphaned Directories</span>
          <span className="text-lg font-bold text-white">{orphanedDirs} folders</span>
        </div>
        <div>
          <span className="block text-white/40">Reclaimable Space</span>
          <span className="text-lg font-bold text-emerald-400">
            {orphanedBytes ? formatBytes(orphanedBytes) : '0 MB'}
          </span>
        </div>
        <div>
          <span className="block text-white/40">Cache Audit Status</span>
          <span className="text-emerald-400 font-semibold">
            {orphanedDirs === 0 ? '✓ Healthy & Synced' : 'Action Available'}
          </span>
        </div>
      </div>
    </section>
  );
}
