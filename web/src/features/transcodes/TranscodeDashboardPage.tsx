import { useCallback, useEffect, useMemo, useState } from 'react';
import { NavLink } from 'react-router';
import { useAuth } from '../../auth/AuthProvider';
import { Icon } from '../../components/icons';
import { AdminAccessGate } from '../manage/components/AdminAccessGate';
import { AdminPinModal } from '../manage/components/AdminPinModal';
import { ProgressRing } from './components/ProgressRing';
import { QueueTranscodeModal } from './components/QueueTranscodeModal';
import {
  fetchTranscodeDashboard,
  cancelTranscodeJob,
  enqueueTranscodeJob,
  type TranscodeDashboardResponse,
  type ActiveTranscodeJob,
} from '../../lib/api/transcodes';
import { fetchManageMovies, type MovieItem } from '../../lib/api/manage';

export function TranscodeDashboardPage() {
  const { role, authenticated, signIn } = useAuth();

  // Admin PIN verification state & manual lock override
  const [adminPin, setAdminPin] = useState<string>(() => sessionStorage.getItem('ms_admin_pin') || '');
  const [isPinUnlocked, setIsPinUnlocked] = useState<boolean>(
    () => sessionStorage.getItem('ms_admin_unlocked') === 'true'
  );
  const [isManuallyLocked, setIsManuallyLocked] = useState<boolean>(
    () => sessionStorage.getItem('ms_admin_manual_lock') === 'true'
  );
  const [pinModalOpen, setPinModalOpen] = useState(false);
  const [pinInputValue, setPinInputValue] = useState('');
  const [pinModalError, setPinModalError] = useState<string | null>(null);

  // Dashboard Data State
  const [data, setData] = useState<TranscodeDashboardResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState<string | null>(null);

  // Queue Transcode Modal State
  const [queueModalOpen, setQueueModalOpen] = useState(false);
  const [allMovies, setAllMovies] = useState<MovieItem[]>([]);

  // Cancel Confirmation Modal State
  const [cancelTarget, setCancelTarget] = useState<ActiveTranscodeJob | null>(null);

  const isAdmin = !isManuallyLocked && (role === 'admin' || isPinUnlocked);

  const loadDashboard = useCallback(async () => {
    if (!isAdmin) {
      setLoading(false);
      return;
    }
    const effectivePin = adminPin || sessionStorage.getItem('ms_admin_pin') || '';
    setLoading(true);
    try {
      const resp = await fetchTranscodeDashboard(effectivePin);
      setData(resp);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, [isAdmin, adminPin]);

  useEffect(() => {
    loadDashboard();
    const interval = setInterval(() => {
      if (isAdmin && document.visibilityState === 'visible') {
        loadDashboard();
      }
    }, 2000);
    return () => clearInterval(interval);
  }, [loadDashboard, isAdmin]);

  // Lazy load library movies for Queue Transcode modal
  useEffect(() => {
    if (isAdmin && queueModalOpen && allMovies.length === 0) {
      fetchManageMovies()
        .then((items) => setAllMovies(items))
        .catch(() => {});
    }
  }, [isAdmin, queueModalOpen, allMovies.length]);

  // Sorted active/queued transcode jobs (unconditional hook before early returns)
  const activeJobs = useMemo(() => {
    const list = data?.active_jobs ? [...data.active_jobs] : [];
    return list.sort((a, b) => {
      // 1. Actively running streams always come first
      if (a.status === 'running' && b.status !== 'running') return -1;
      if (a.status !== 'running' && b.status === 'running') return 1;
      // 2. Highest percentage first among running streams
      if (a.status === 'running' && b.status === 'running') {
        return b.percent - a.percent;
      }
      // 3. Highest priority first among queued streams
      if (b.priority !== a.priority) {
        return b.priority - a.priority;
      }
      return 0;
    });
  }, [data?.active_jobs]);

  const handleVerifyPin = async (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    setPinModalError(null);
    if (!pinInputValue.trim()) {
      setPinModalError('Please enter your server Admin PIN');
      return;
    }

    try {
      setBusy(true);
      const { verifyAdminPin } = await import('../../lib/api/manage');
      const res = await verifyAdminPin(pinInputValue.trim());
      if (res.success) {
        sessionStorage.setItem('ms_admin_pin', pinInputValue.trim());
        sessionStorage.setItem('ms_admin_unlocked', 'true');
        sessionStorage.removeItem('ms_admin_manual_lock');
        setAdminPin(pinInputValue.trim());
        setIsPinUnlocked(true);
        setIsManuallyLocked(false);
        setPinModalOpen(false);
        setPinInputValue('');
        setFeedback('Administrator privileges unlocked.');
        setTimeout(() => setFeedback(null), 3000);
      } else {
        setPinModalError(res.error || 'Incorrect Admin PIN.');
      }
    } catch {
      setPinModalError('Failed to verify PIN with media server.');
    } finally {
      setBusy(false);
    }
  };

  const handleLockSession = () => {
    sessionStorage.removeItem('ms_admin_pin');
    sessionStorage.removeItem('ms_admin_unlocked');
    sessionStorage.setItem('ms_admin_manual_lock', 'true');
    setAdminPin('');
    setIsPinUnlocked(false);
    setIsManuallyLocked(true);
    setFeedback('Administrator session locked.');
    setTimeout(() => setFeedback(null), 3000);
  };

  const handleCancelJob = async () => {
    if (!cancelTarget) return;
    const effectivePin = adminPin || sessionStorage.getItem('ms_admin_pin') || '';
    try {
      setBusy(true);
      await cancelTranscodeJob(cancelTarget.filename, effectivePin);
      setFeedback(`Canceled transcode for "${cancelTarget.title}".`);
      setTimeout(() => setFeedback(null), 3500);
      setCancelTarget(null);
      await loadDashboard();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  const handleQueueTranscode = async (filename: string, preset: string, priority: number) => {
    const effectivePin = adminPin || sessionStorage.getItem('ms_admin_pin') || '';
    setBusy(true);
    try {
      await enqueueTranscodeJob(filename, preset, priority, effectivePin);
      setFeedback('Transcode job successfully queued.');
      setTimeout(() => setFeedback(null), 3500);
      await loadDashboard();
    } finally {
      setBusy(false);
    }
  };

  // 1. Gated Access View for Non-Admins
  if (!isAdmin) {
    return (
      <>
        <AdminAccessGate
          authenticated={authenticated}
          onOpenPinModal={() => setPinModalOpen(true)}
          onSignIn={signIn}
        />
        <AdminPinModal
          isOpen={pinModalOpen}
          pinValue={pinInputValue}
          error={pinModalError}
          onChangePin={setPinInputValue}
          onClose={() => {
            setPinModalOpen(false);
            setPinModalError(null);
            setPinInputValue('');
          }}
          onSubmit={() => { void handleVerifyPin(); }}
        />
      </>
    );
  }

  // 2. Loading State During Auth Transition & Cold Data Fetch
  if (!data && !error) {
    return (
      <div className="flex flex-col items-center justify-center min-h-[50vh] space-y-4 animate-fade-in">
        <div className="flex h-14 w-14 items-center justify-center rounded-2xl bg-brand-500/10 text-brand-400 border border-brand-500/20">
          <div className="h-7 w-7 animate-spin rounded-full border-2 border-brand-500 border-t-transparent" />
        </div>
        <p className="text-sm font-medium text-white/70">Connecting to Transcoding Command Center...</p>
      </div>
    );
  }

  // 3. Error Fallback State if Initial Load Fails
  if (!data && error) {
    return (
      <div className="rounded-3xl border border-rose-500/30 bg-rose-500/10 p-8 sm:p-12 text-center max-w-lg mx-auto space-y-4 my-12 animate-fade-in">
        <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl bg-rose-500/20 text-rose-400 text-2xl">
          ⚠️
        </div>
        <div className="space-y-1">
          <h3 className="text-base font-bold text-white">Failed to load Transcode Dashboard</h3>
          <p className="text-xs text-rose-300">{error}</p>
        </div>
        <button
          type="button"
          onClick={() => void loadDashboard()}
          className="rounded-full brand-gradient px-5 py-2 text-xs font-bold text-white shadow-md hover:scale-105 active:scale-95 transition cursor-pointer"
        >
          ↻ Retry Connection
        </button>
      </div>
    );
  }

  const summary = data?.summary;
  const recentJobs = data?.recent_jobs ?? [];

  return (
    <div className="space-y-8 animate-fade-in pb-16">
      {/* Navigation Breadcrumb & Admin Toolbar */}
      <div className="flex flex-wrap items-center justify-between gap-3 border-b border-white/10 pb-4">
        <div className="flex items-center gap-3">
          <NavLink
            to="/"
            className="card-ring rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 hover:text-white transition flex items-center gap-1.5"
          >
            ← Back to Library
          </NavLink>
          <span className="flex items-center gap-1.5 rounded-full border border-brand-500/30 bg-brand-500/10 px-3.5 py-1.5 text-xs font-semibold text-brand-300">
            <Icon name="shield" size={13} />
            <span>Admin Zone</span>
          </span>
        </div>

        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => setQueueModalOpen(true)}
            className="brand-gradient rounded-full px-4 py-2 text-xs font-bold text-white shadow-md shadow-brand-500/20 hover:scale-105 active:scale-95 transition flex items-center gap-1.5 cursor-pointer"
          >
            <Icon name="bolt" size={14} />
            <span>Queue Transcode</span>
          </button>

          <button
            type="button"
            onClick={loadDashboard}
            disabled={loading}
            className="rounded-full border border-white/15 bg-white/5 px-3.5 py-2 text-xs font-medium text-white/70 hover:bg-white/10 hover:text-white transition cursor-pointer"
            title="Refresh Telemetry"
          >
            ↻
          </button>

          <button
            type="button"
            onClick={handleLockSession}
            className="rounded-full border border-white/15 bg-white/5 px-3.5 py-2 text-xs font-medium text-white/60 hover:text-white hover:bg-white/10 transition cursor-pointer"
            title="Lock Admin Session"
          >
            Lock
          </button>
        </div>
      </div>

      {/* Toast Feedback */}
      {feedback ? (
        <div className="rounded-2xl border border-emerald-500/30 bg-emerald-500/15 p-3.5 text-xs font-medium text-emerald-300 animate-fade-in flex items-center justify-between">
          <span>{feedback}</span>
          <button type="button" onClick={() => setFeedback(null)} className="text-white/40 hover:text-white">
            ✕
          </button>
        </div>
      ) : null}

      {error ? (
        <div className="rounded-2xl border border-rose-500/30 bg-rose-500/15 p-3.5 text-xs font-medium text-rose-300 animate-fade-in">
          {error}
        </div>
      ) : null}

      {/* Dashboard Title & Realtime Badge */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <div className="flex items-center gap-3">
            <h1 className="text-2xl sm:text-3xl font-extrabold tracking-tight text-white">
              Transcoding Command Center
            </h1>
            <span className="relative flex h-3 w-3">
              <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-brand-400 opacity-75"></span>
              <span className="relative inline-flex rounded-full h-3 w-3 bg-brand-500"></span>
            </span>
          </div>
          <p className="text-xs sm:text-sm text-white/50 mt-1">
            Real-time multi-GPU adaptive transcoding telemetry, fMP4 segment buffers, and disk allocation
          </p>
        </div>

        <div className="flex items-center gap-2 self-start sm:self-auto">
          <span className="text-xs font-mono text-white/40">
            Cadence: 2s live poll
          </span>
        </div>
      </div>

      {/* Top Summary Metrics Strip (KPIs) */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3.5 sm:gap-4">
        {/* Active & Queued Tasks */}
        <div className="glass-card rounded-2xl border border-white/10 bg-obsidian-850 p-4 sm:p-5 shadow-lg relative overflow-hidden">
          <div className="flex items-center justify-between">
            <span className="text-[11px] sm:text-xs font-semibold text-white/50 uppercase tracking-wider">
              Active Transcodes
            </span>
            <span className="flex h-7 w-7 items-center justify-center rounded-xl bg-brand-500/15 text-brand-400 text-xs font-bold">
              ⚡
            </span>
          </div>
          <div className="mt-3 flex items-baseline gap-2">
            <span className="text-2xl sm:text-3xl font-black text-white tracking-tight">
              {summary ? summary.active_count : activeJobs.length}
            </span>
            <span className="text-xs text-white/40">
              ({summary?.running_count ?? 0} running, {summary?.queued_count ?? 0} queued)
            </span>
          </div>
          <div className="mt-2 flex items-center gap-1.5 text-[11px] text-white/60">
            <span className="inline-block h-1.5 w-1.5 rounded-full bg-emerald-400"></span>
            <span>Dual-GPU chunk scheduler online</span>
          </div>
        </div>

        {/* Aggregated Total ETA */}
        <div className="glass-card rounded-2xl border border-white/10 bg-obsidian-850 p-4 sm:p-5 shadow-lg relative overflow-hidden">
          <div className="flex items-center justify-between">
            <span className="text-[11px] sm:text-xs font-semibold text-white/50 uppercase tracking-wider">
              Overall Queue ETA
            </span>
            <span className="flex h-7 w-7 items-center justify-center rounded-xl bg-sky-500/15 text-sky-400 text-xs font-bold">
              ⏱
            </span>
          </div>
          <div className="mt-3 flex items-baseline gap-2">
            <span className="text-2xl sm:text-3xl font-black text-sky-300 tracking-tight font-mono">
              {summary?.overall_eta_str || '0s'}
            </span>
          </div>
          <div className="mt-2 text-[11px] text-white/50">
            Concurrent dual-adapter estimated completion
          </div>
        </div>

        {/* Live Storage Footprint */}
        <div className="glass-card rounded-2xl border border-white/10 bg-obsidian-850 p-4 sm:p-5 shadow-lg relative overflow-hidden">
          <div className="flex items-center justify-between">
            <span className="text-[11px] sm:text-xs font-semibold text-white/50 uppercase tracking-wider">
              Output Disk Footprint
            </span>
            <span className="flex h-7 w-7 items-center justify-center rounded-xl bg-amber-500/15 text-amber-400 text-xs font-bold">
              💾
            </span>
          </div>
          <div className="mt-3 flex items-baseline gap-1.5">
            <span className="text-xl sm:text-2xl font-black text-white tracking-tight">
              {summary?.total_current_size_str || '0 B'}
            </span>
            <span className="text-xs text-white/40">
              / ~{summary?.total_estimated_size_str || '0 B'}
            </span>
          </div>
          <div className="mt-2 text-[11px] text-white/50">
            Written to E:\MediaServer\cache\hls\
          </div>
        </div>

        {/* Hardware Telemetry Engine */}
        <div className="glass-card rounded-2xl border border-white/10 bg-obsidian-850 p-4 sm:p-5 shadow-lg relative overflow-hidden">
          <div className="flex items-center justify-between">
            <span className="text-[11px] sm:text-xs font-semibold text-white/50 uppercase tracking-wider">
              Hardware Adapters
            </span>
            <span className="flex h-7 w-7 items-center justify-center rounded-xl bg-purple-500/15 text-purple-400 text-xs font-bold">
              🎮
            </span>
          </div>
          <div className="mt-3 space-y-1 text-xs">
            <div className="flex items-center justify-between">
              <span className="text-white/80 font-medium">RX 560X (dx11:1)</span>
              <span className="text-[10px] text-emerald-400 font-semibold">
                {summary?.hardware_engine?.primary?.status || 'Standby'}
              </span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-white/60 font-medium">Vega 8 (dx11:0)</span>
              <span className="text-[10px] text-emerald-400 font-semibold">
                {summary?.hardware_engine?.secondary?.status || 'Standby'}
              </span>
            </div>
          </div>
          <div className="mt-2 text-[10px] text-white/40">
            AMF D3D11VA Hardware Encoders
          </div>
        </div>
      </div>

      {/* Active & Queued Streams Section */}
      <section className="space-y-4" aria-label="Active Transcoding Streams">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-bold text-white tracking-wide flex items-center gap-2">
            <span>In-Progress &amp; Queued Jobs</span>
            <span className="rounded-full bg-white/10 px-2.5 py-0.5 text-xs text-white/60 font-medium">
              {activeJobs.length}
            </span>
          </h2>
          {summary && summary.running_count > 0 ? (
            <span className="flex items-center gap-1.5 text-xs text-emerald-400 font-semibold bg-emerald-500/10 border border-emerald-500/25 px-3 py-1 rounded-full">
              <span className="relative flex h-2 w-2">
                <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span>
                <span className="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span>
              </span>
              <span>{summary.running_count} Active Encoders First</span>
            </span>
          ) : null}
        </div>

        {activeJobs.length === 0 ? (
          <div className="rounded-3xl border border-white/10 bg-obsidian-900/40 p-10 sm:p-14 text-center space-y-4">
            <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-3xl bg-white/5 text-white/30 text-2xl">
              🎬
            </div>
            <div className="space-y-1 max-w-md mx-auto">
              <h3 className="text-base font-bold text-white">No active transcoding streams</h3>
              <p className="text-xs text-white/50">
                All media files are currently idle or served via Direct Play without server CPU/GPU load.
              </p>
            </div>
            <button
              type="button"
              onClick={() => setQueueModalOpen(true)}
              className="mt-2 rounded-full brand-gradient px-5 py-2 text-xs font-bold text-white shadow-md hover:scale-105 active:scale-95 transition cursor-pointer"
            >
              + Queue a Transcode Job
            </button>
          </div>
        ) : (
          <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
            {activeJobs.map((job, idx) => (
              <div
                key={job.id}
                className={`glass-card rounded-3xl border p-4 sm:p-5 shadow-xl transition duration-200 flex flex-col justify-between space-y-4 relative overflow-hidden group ${
                  job.status === 'running'
                    ? 'border-emerald-500/40 bg-obsidian-850 shadow-emerald-500/10'
                    : 'border-white/10 bg-obsidian-850/80 hover:border-white/20'
                }`}
              >
                {/* Background Ambient Glow */}
                <div
                  className={`pointer-events-none absolute -right-20 -bottom-20 w-60 h-60 rounded-full blur-3xl transition duration-500 ${
                    job.status === 'running'
                      ? 'bg-emerald-500/10 group-hover:bg-emerald-500/20'
                      : 'bg-brand-500/5 group-hover:bg-brand-500/10'
                  }`}
                />

                <div className="flex gap-4">
                  {/* Poster Thumbnail */}
                  <div className="w-16 h-24 sm:w-20 sm:h-28 rounded-2xl overflow-hidden bg-obsidian-950 border border-white/10 flex-shrink-0 relative shadow-md">
                    {job.poster_url ? (
                      <img
                        src={job.poster_url}
                        alt={job.title}
                        className="w-full h-full object-cover group-hover:scale-105 transition duration-300"
                        loading="lazy"
                        onError={(e) => {
                          (e.target as HTMLElement).style.display = 'none';
                        }}
                      />
                    ) : null}
                    <div className="w-full h-full flex items-center justify-center text-white/20 text-2xl select-none">
                      🎬
                    </div>
                  </div>

                  {/* Title & Metadata */}
                  <div className="flex-1 min-w-0 flex flex-col justify-between">
                    <div>
                      <div className="flex items-start justify-between gap-2">
                        <NavLink
                          to={`/movie/${encodeURIComponent(job.filename)}`}
                          className="text-base sm:text-lg font-bold text-white hover:text-brand-400 transition truncate"
                          title={job.title}
                        >
                          {job.title}
                        </NavLink>
                        <div className="flex items-center gap-1.5 flex-shrink-0">
                          {job.status === 'running' ? (
                            <span className="flex items-center gap-1 text-[10px] font-bold uppercase tracking-wider px-2 py-0.5 rounded-full bg-emerald-500/20 text-emerald-300 border border-emerald-500/30">
                              <span className="h-1.5 w-1.5 rounded-full bg-emerald-400 animate-pulse" />
                              <span>Active</span>
                            </span>
                          ) : (
                            <span className="text-[10px] font-semibold uppercase tracking-wider px-2 py-0.5 rounded-full bg-white/5 text-white/50 border border-white/10">
                              Queued #{idx + 1}
                            </span>
                          )}
                          <span className="text-[10px] font-bold uppercase tracking-wider px-2.5 py-0.5 rounded-full bg-brand-500/20 text-brand-300 border border-brand-500/30">
                            {job.preset_label}
                          </span>
                        </div>
                      </div>
                      <div className="flex items-center gap-2 text-xs text-white/40 mt-1">
                        {job.year ? <span>{job.year}</span> : null}
                        {job.runtime ? <span>• {job.runtime} min</span> : null}
                        <span>• Priority {job.priority}</span>
                      </div>
                    </div>

                    {/* Telemetry Metrics Row */}
                    <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 pt-2 text-xs">
                      <div className="rounded-xl border border-white/5 bg-white/[0.02] p-2">
                        <span className="block text-[10px] text-white/40 uppercase">Speed</span>
                        <span className="font-bold text-brand-300">
                          {job.speed_str || (job.status === 'queued' ? 'Queued' : '1.0x')}
                        </span>
                      </div>

                      <div className="rounded-xl border border-white/5 bg-white/[0.02] p-2">
                        <span className="block text-[10px] text-white/40 uppercase">Rate</span>
                        <span className="font-bold text-white">
                          {job.fps_str || (job.status === 'queued' ? '-' : '60 fps')}
                        </span>
                      </div>

                      <div className="rounded-xl border border-white/5 bg-white/[0.02] p-2">
                        <span className="block text-[10px] text-white/40 uppercase">Progress Time</span>
                        <span className="font-medium text-white/80">
                          {job.encoded_str && job.duration_str
                            ? `${job.encoded_str} / ${job.duration_str}`
                            : '0:00'}
                        </span>
                      </div>

                      <div className="rounded-xl border border-white/5 bg-white/[0.02] p-2">
                        <span className="block text-[10px] text-white/40 uppercase">ETA</span>
                        <span className="font-mono font-bold text-sky-300">
                          {job.eta_str}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>

                {/* Progress Strip & Size Estimates */}
                <div className="space-y-2 border-t border-white/5 pt-3">
                  <div className="flex items-center justify-between text-xs">
                    <div className="flex items-center gap-3">
                      <ProgressRing
                        value={job.percent}
                        size={48}
                        strokeWidth={5}
                        status={job.status}
                      />
                      <div>
                        <div className="flex items-center gap-2">
                          <span className="text-sm font-extrabold text-white">
                            {job.percent.toFixed(1)}% Completed
                          </span>
                          <span
                            className={`text-[10px] font-semibold px-2 py-0.5 rounded-full ${
                              job.status === 'running'
                                ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/30'
                                : 'bg-amber-500/20 text-amber-300 border border-amber-500/30'
                            }`}
                          >
                            {job.status.toUpperCase()}
                          </span>
                        </div>
                        <p className="text-[11px] text-white/50">
                          Generated: <strong className="text-white">{job.current_size_str}</strong> • Projected Final:{' '}
                          <strong className="text-white/80">~{job.estimated_total_size_str}</strong>
                        </p>
                      </div>
                    </div>

                    <div className="flex items-center gap-2">
                      <NavLink
                        to={`/watch/${encodeURIComponent(job.filename)}`}
                        className="rounded-full border border-white/10 bg-white/5 px-3 py-1.5 text-xs font-semibold text-white/80 hover:bg-white/10 hover:text-white transition"
                      >
                        Watch Stream
                      </NavLink>
                      <button
                        type="button"
                        onClick={() => setCancelTarget(job)}
                        className="rounded-full border border-rose-500/30 bg-rose-500/10 px-3 py-1.5 text-xs font-semibold text-rose-300 hover:bg-rose-500/20 transition cursor-pointer"
                      >
                        Cancel
                      </button>
                    </div>
                  </div>

                  {/* Horizontal Linear Fill Bar */}
                  <div className="h-1.5 w-full rounded-full bg-white/10 overflow-hidden relative">
                    <div
                      className="h-full rounded-full bg-gradient-to-r from-brand-600 via-brand-500 to-brand-400 transition-all duration-500"
                      style={{ width: `${Math.min(100, Math.max(0, job.percent))}%` }}
                    />
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </section>

      {/* Recent Transcode History Section */}
      <section className="space-y-4 pt-6" aria-label="Recent Transcode History">
        <div className="flex items-center justify-between border-b border-white/10 pb-3">
          <div className="flex items-center gap-2">
            <h2 className="text-lg font-bold text-white tracking-wide">
              Recent Job History
            </h2>
            <span className="text-xs text-white/40">
              (Last {recentJobs.length} completed / finished jobs)
            </span>
          </div>
        </div>

        {recentJobs.length === 0 ? (
          <p className="text-xs text-white/40 italic py-2">
            No completed transcode history recorded in database.
          </p>
        ) : (
          <div className="overflow-x-auto rounded-2xl border border-white/10 bg-obsidian-900/50">
            <table className="w-full text-left text-xs text-white/70">
              <thead className="border-b border-white/10 bg-white/[0.02] text-[11px] font-semibold uppercase text-white/40">
                <tr>
                  <th className="py-3 px-4">Title</th>
                  <th className="py-3 px-4">Preset</th>
                  <th className="py-3 px-4">Status</th>
                  <th className="py-3 px-4">Duration</th>
                  <th className="py-3 px-4">Final Output Size</th>
                  <th className="py-3 px-4">Finished At</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-white/5">
                {recentJobs.map((item) => (
                  <tr key={item.id} className="hover:bg-white/[0.02] transition">
                    <td className="py-3 px-4 font-semibold text-white truncate max-w-xs">
                      {item.title}
                    </td>
                    <td className="py-3 px-4">
                      <span className="text-[11px] px-2 py-0.5 rounded-full bg-white/5 border border-white/10 text-white/70">
                        {item.preset_label}
                      </span>
                    </td>
                    <td className="py-3 px-4">
                      <span
                        className={`text-[11px] font-bold uppercase tracking-wider px-2 py-0.5 rounded-full ${
                          item.status === 'completed'
                            ? 'bg-emerald-500/15 text-emerald-300 border border-emerald-500/30'
                            : item.status === 'failed'
                            ? 'bg-rose-500/15 text-rose-300 border border-rose-500/30'
                            : 'bg-white/10 text-white/50'
                        }`}
                      >
                        {item.status}
                      </span>
                      {item.error ? (
                        <p className="text-[10px] text-rose-400 mt-0.5 max-w-xs truncate" title={item.error}>
                          {item.error}
                        </p>
                      ) : null}
                    </td>
                    <td className="py-3 px-4 font-mono text-white/60">
                      {item.elapsed_str}
                    </td>
                    <td className="py-3 px-4 font-mono text-white/80">
                      {item.current_size_str}
                    </td>
                    <td className="py-3 px-4 text-white/40">
                      {new Date(item.updated_at).toLocaleTimeString([], {
                        hour: '2-digit',
                        minute: '2-digit',
                        month: 'short',
                        day: 'numeric',
                      })}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* Queue Transcode Modal */}
      <QueueTranscodeModal
        isOpen={queueModalOpen}
        movies={allMovies}
        onClose={() => setQueueModalOpen(false)}
        onSubmit={handleQueueTranscode}
        busy={busy}
      />

      {/* Cancel Confirmation Dialog */}
      {cancelTarget && typeof document !== 'undefined' ? (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-md animate-fade-in"
          onClick={() => setCancelTarget(null)}
        >
          <div
            className="glass-card max-w-md w-full rounded-3xl p-6 sm:p-7 space-y-5 border border-rose-500/30 shadow-2xl animate-scale-in"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-2xl bg-rose-500/20 text-rose-400 text-lg">
                ⚠️
              </div>
              <div>
                <h4 className="text-base font-bold text-white">Cancel Transcode Job?</h4>
                <p className="text-xs text-white/50">This terminates active chunk encoders</p>
              </div>
            </div>

            <p className="text-xs sm:text-sm text-white/70 leading-relaxed">
              Are you sure you want to cancel the transcode job for{' '}
              <strong className="text-white">&ldquo;{cancelTarget.title}&rdquo;</strong>?
              Any segments already written to disk will remain cached.
            </p>

            <div className="flex items-center justify-end gap-3 pt-2">
              <button
                type="button"
                onClick={() => setCancelTarget(null)}
                disabled={busy}
                className="px-4 py-2 rounded-full border border-white/15 bg-white/5 text-xs font-semibold text-white/70 hover:bg-white/10 hover:text-white transition cursor-pointer"
              >
                Keep Running
              </button>
              <button
                type="button"
                onClick={handleCancelJob}
                disabled={busy}
                className="px-5 py-2 rounded-full bg-rose-600 hover:bg-rose-700 text-xs font-bold text-white shadow-lg shadow-rose-600/30 transition cursor-pointer"
              >
                {busy ? 'Canceling...' : 'Confirm Cancel'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

export default TranscodeDashboardPage;
