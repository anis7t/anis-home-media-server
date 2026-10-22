import { NavLink } from 'react-router';
import { Icon } from '../../../components/icons';

interface AdminAccessGateProps {
  readonly authenticated: boolean;
  readonly onOpenPinModal: () => void;
  readonly onSignIn: () => void;
}

export function AdminAccessGate({
  authenticated,
  onOpenPinModal,
  onSignIn,
}: AdminAccessGateProps) {
  return (
    <div className="mx-auto max-w-3xl space-y-8 animate-fade-in pb-16">
      {/* Navigation Breadcrumb */}
      <div className="flex items-center justify-between">
        <NavLink
          to="/"
          className="card-ring rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 hover:text-white transition flex items-center gap-1.5"
        >
          ← Back to Library
        </NavLink>
        <span className="flex items-center gap-1.5 rounded-full border border-amber-500/30 bg-amber-500/10 px-3.5 py-1.5 text-xs font-semibold text-amber-300">
          <Icon name="shield" size={13} />
          <span>Restricted Zone</span>
        </span>
      </div>

      {/* Access Denied Hero Card */}
      <div className="relative overflow-hidden rounded-3xl border border-amber-500/30 bg-obsidian-950/80 p-8 sm:p-12 shadow-[0_25px_60px_-15px_rgba(0,0,0,0.8),0_0_50px_rgba(245,158,11,0.08)] backdrop-blur-2xl text-center space-y-8">
        {/* Subtle Ambient Radial Lighting */}
        <div className="pointer-events-none absolute -top-24 left-1/2 -translate-x-1/2 w-96 h-96 rounded-full bg-gradient-to-b from-amber-500/15 via-brand-500/5 to-transparent blur-3xl" />

        {/* Glowing Shield Icon */}
        <div className="relative mx-auto flex h-20 w-20 items-center justify-center rounded-3xl border border-amber-500/40 bg-gradient-to-b from-amber-500/20 to-amber-950/40 shadow-lg shadow-amber-500/10 text-amber-400">
          <Icon name="shield" size={38} className="animate-pulse" />
          <div className="absolute -inset-1 rounded-3xl bg-amber-500/20 blur-md -z-10" />
        </div>

        <div className="relative space-y-3 max-w-xl mx-auto">
          <h1 className="text-2xl sm:text-3xl font-extrabold tracking-tight text-white">
            Administrator Access Required
          </h1>
          <p className="text-sm sm:text-base text-white/70 leading-relaxed">
            Library management, storage pool allocation, cache purging, and media retention controls are protected by server security policy.
          </p>
        </div>

        {/* Protected Capabilities Grid */}
        <div className="relative grid grid-cols-1 sm:grid-cols-2 gap-3 text-left max-w-xl mx-auto">
          <div className="flex items-start gap-3 rounded-2xl border border-white/10 bg-white/[0.03] p-3.5">
            <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-xl bg-amber-500/15 text-amber-400 text-sm">
              💾
            </span>
            <div>
              <h4 className="text-xs font-bold text-white">Storage Pool Telemetry</h4>
              <p className="text-[11px] text-white/50">D: &amp; E: SSD drive headroom and cache analysis</p>
            </div>
          </div>

          <div className="flex items-start gap-3 rounded-2xl border border-white/10 bg-white/[0.03] p-3.5">
            <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-xl bg-sky-500/15 text-sky-400 text-sm">
              📦
            </span>
            <div>
              <h4 className="text-xs font-bold text-white">Cold Tier Archival</h4>
              <p className="text-[11px] text-white/50">Zero-stutter streaming with raw file offloading</p>
            </div>
          </div>

          <div className="flex items-start gap-3 rounded-2xl border border-white/10 bg-white/[0.03] p-3.5">
            <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-xl bg-rose-500/15 text-rose-400 text-sm">
              🗑️
            </span>
            <div>
              <h4 className="text-xs font-bold text-white">Permanent Purge Guard</h4>
              <p className="text-[11px] text-white/50">Secure multi-volume deletion &amp; orphan cleanup</p>
            </div>
          </div>

          <div className="flex items-start gap-3 rounded-2xl border border-white/10 bg-white/[0.03] p-3.5">
            <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-xl bg-emerald-500/15 text-emerald-400 text-sm">
              ↻
            </span>
            <div>
              <h4 className="text-xs font-bold text-white">Library Rescan &amp; Index</h4>
              <p className="text-[11px] text-white/50">Dual-GPU transcode scheduler &amp; metadata sync</p>
            </div>
          </div>
        </div>

        {/* Action Buttons */}
        <div className="relative flex flex-col sm:flex-row items-center justify-center gap-3 pt-2">
          <button
            type="button"
            onClick={onOpenPinModal}
            className="w-full sm:w-auto card-ring rounded-full brand-gradient px-6 py-3 text-sm font-bold text-white shadow-lg shadow-brand-500/25 hover:shadow-brand-500/40 hover:scale-[1.02] active:scale-[0.98] transition flex items-center justify-center gap-2 cursor-pointer"
          >
            <Icon name="shield" size={16} />
            <span>Unlock with Admin PIN</span>
          </button>

          <button
            type="button"
            onClick={onSignIn}
            className="w-full sm:w-auto card-ring rounded-full border border-white/20 bg-white/5 hover:bg-white/10 px-6 py-3 text-sm font-semibold text-white/90 hover:text-white transition flex items-center justify-center gap-2 cursor-pointer"
          >
            <svg className="w-4 h-4" viewBox="0 0 24 24">
              <path
                fill="currentColor"
                d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
              />
              <path
                fill="currentColor"
                d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
              />
              <path
                fill="currentColor"
                d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.06H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.94l2.85-2.22.81-.63z"
              />
              <path
                fill="currentColor"
                d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.06l3.66 2.84c.87-2.6 3.3-4.52 6.16-4.52z"
              />
            </svg>
            <span>{authenticated ? 'Switch Account' : 'Sign in with Google'}</span>
          </button>
        </div>
      </div>
    </div>
  );
}
