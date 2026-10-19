import { Icon } from '../../../components/icons';
import type { StorageAuditData } from '../../../lib/api/manage';

interface StoragePoolHudProps {
  readonly auditData: StorageAuditData | null;
  readonly loading: boolean;
}

export function StoragePoolHud({ auditData, loading }: StoragePoolHudProps) {
  if (auditData?.storage) {
    return (
      <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-5 space-y-3">
        <div className="flex items-center justify-between text-xs sm:text-sm">
          <span className="font-semibold text-white flex items-center gap-2">
            <Icon name="disc" className="text-brand-400" />
            Storage Pool Utilization
          </span>
          <span className="text-white/60">
            {auditData.storage.free_str ?? 'Calculating…'} free of{' '}
            {auditData.storage.total_str ?? '…'}
          </span>
        </div>

        <div className="h-3 w-full rounded-full bg-white/10 overflow-hidden">
          <div
            className="h-full rounded-full brand-gradient transition-all duration-500"
            style={{ width: `${Math.min(100, auditData.storage.percent ?? 0)}%` }}
          />
        </div>

        <div className="flex flex-wrap items-center justify-between gap-2 text-[11px] text-white/40">
          <span>Drive D: (Raw Media) + Drive E: (SSD Runtime)</span>
          {auditData.storage.drives
            ?.filter((d) => {
              const letter = d.drive.charAt(0).toUpperCase();
              return letter === 'D' || letter === 'E';
            })
            .map((d) => (
              <span key={d.drive} className="text-white/50">
                {d.drive} {d.free_str} free ({d.percent}%)
              </span>
            ))}
          <span className="font-semibold text-white/70">
            {auditData.storage.percent ?? 0}% Allocated
          </span>
        </div>
      </div>
    );
  }

  if (loading) {
    return (
      <div className="rounded-2xl border border-white/10 bg-obsidian-900/40 p-5 space-y-3 animate-pulse">
        <div className="flex items-center justify-between text-xs sm:text-sm">
          <span className="font-semibold text-white/70 flex items-center gap-2">
            <div className="h-3.5 w-3.5 rounded-full border-2 border-white/20 border-t-brand-500 animate-spin" />
            Auditing Storage Pool &amp; Cache Integrity…
          </span>
          <span className="text-white/40 text-xs">
            Analyzing disk utilization &amp; stream chunk integrity…
          </span>
        </div>
        <div className="h-3 w-full rounded-full bg-white/5 overflow-hidden">
          <div className="h-full w-1/3 rounded-full bg-brand-500/30 animate-pulse" />
        </div>
        <div className="flex items-center justify-between text-[11px] text-white/40">
          <span>Examining storage roots (D: / E:)</span>
          <span>Scanning cache directories…</span>
        </div>
      </div>
    );
  }

  return null;
}
