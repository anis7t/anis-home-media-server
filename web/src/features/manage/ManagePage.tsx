import { useCallback, useEffect, useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import { NavLink } from 'react-router';
import { useAuth } from '../../auth/AuthProvider';
import { Icon } from '../../components/icons';
import { posterUrl } from '../../lib/api/poster';

interface StorageAuditData {
  storage: {
    free_bytes?: number;
    free_str?: string;
    total_bytes?: number;
    total_str?: string;
    percent?: number;
    drives?: Array<{
      drive: string;
      free_str: string;
      total_str: string;
      used_str: string;
      percent: number;
    }>;
  };
  audit: {
    total_orphaned_dirs?: number;
    total_orphaned_bytes?: number;
    orphaned_hls_dirs?: string[];
    total_active_bytes?: number;
    total_active_dirs?: number;
    active_hls?: Array<{
      source_file: string;
      size_bytes: number;
      name: string;
      path: string;
    }>;
  };
}

interface StorageSettings {
  retention_policy: string;
  archive_dir: string;
  allowed_policies: string[];
}

interface MovieItem {
  filename: string;
  title: string;
  year?: number;
  duration?: number;
  poster?: string;
  percent?: number;
  position?: number;
  rating?: number;
  runtime?: number;
  updated_at?: string;
}

type FilterCategory = 'all' | 'hls' | 'direct' | 'watched' | 'unwatched';
type SortField = 'title' | 'year' | 'recent';

function formatBytes(bytes?: number): string {
  if (!bytes || bytes <= 0) return '0 MB';
  const gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1) return `${gb.toFixed(2)} GB`;
  const mb = bytes / (1024 * 1024);
  return `${mb.toFixed(1)} MB`;
}

export function ManagePage() {
  const { role, email } = useAuth();
  const [auditData, setAuditData] = useState<StorageAuditData | null>(null);
  const [settings, setSettings] = useState<StorageSettings | null>(null);
  const [movies, setMovies] = useState<MovieItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [scanning, setScanning] = useState(false);
  const [feedback, setFeedback] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Admin PIN verification state
  const [adminPin, setAdminPin] = useState<string>(() => sessionStorage.getItem('ms_admin_pin') || '');
  const [isPinUnlocked, setIsPinUnlocked] = useState<boolean>(
    () => sessionStorage.getItem('ms_admin_unlocked') === 'true'
  );
  const [pinModalOpen, setPinModalOpen] = useState(false);
  const [pinInputValue, setPinInputValue] = useState('');
  const [pinModalError, setPinModalError] = useState<string | null>(null);

  // In-delete modal PIN input
  const [modalPinInput, setModalPinInput] = useState('');

  // Search & Filter state
  const [searchQuery, setSearchQuery] = useState('');
  const [activeFilter, setActiveFilter] = useState<FilterCategory>('all');
  const [sortBy, setSortBy] = useState<SortField>('title');

  // Purge modal state
  const [deleteTarget, setDeleteTarget] = useState<MovieItem | null>(null);
  const [deleting, setDeleting] = useState(false);

  // User is considered admin if signed in with Google as admin OR unlocked via PIN
  const isAdmin = role === 'admin' || isPinUnlocked;

  const getAdminHeaders = useCallback(
    (overridePin?: string): Record<string, string> => {
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      const effectivePin = overridePin || adminPin || sessionStorage.getItem('ms_admin_pin') || '';
      if (effectivePin) {
        headers['X-Admin-Pin'] = effectivePin;
      }
      return headers;
    },
    [adminPin]
  );

  const loadData = useCallback(async () => {
    // 1. Fetch movies immediately so the inventory renders in < 100ms
    void fetch('/api/movies')
      .then((res) => (res.ok ? res.json() : null))
      .then((body: { movies?: MovieItem[] } | MovieItem[] | null) => {
        if (body) {
          setMovies(Array.isArray(body) ? body : body.movies ?? []);
        }
      })
      .catch((err) => {
        setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        setLoading(false);
      });

    // 2. Fetch storage settings in parallel
    void fetch('/api/storage/settings')
      .then((res) => (res.ok ? res.json() : null))
      .then((data: StorageSettings | null) => {
        if (data) setSettings(data);
      })
      .catch(() => {});

    // 3. Fetch storage audit in background (can take several seconds on large drives)
    void fetch('/api/storage/audit')
      .then((res) => (res.ok ? res.json() : null))
      .then((data: StorageAuditData | null) => {
        if (data) setAuditData(data);
      })
      .catch(() => {});
  }, []);

  useEffect(() => {
    void loadData();
  }, [loadData]);

  // Escape key handler for dialogs
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (deleteTarget && !deleting) setDeleteTarget(null);
        if (pinModalOpen) setPinModalOpen(false);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [deleteTarget, deleting, pinModalOpen]);

  // Active HLS lookup map (from audit telemetry)
  const activeHlsMap = useMemo(() => {
    const map = new Map<string, { size_bytes: number }>();
    if (auditData?.audit?.active_hls) {
      for (const item of auditData.audit.active_hls) {
        if (item.source_file) {
          map.set(item.source_file.toLowerCase(), item);
          const base = item.source_file.split(/[\/\\]/).pop()?.toLowerCase();
          if (base) map.set(base, item);
        }
      }
    }
    return map;
  }, [auditData]);

  // Filtered & sorted movies
  const filteredMovies = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    return movies
      .filter((m) => {
        if (q) {
          const matchTitle = m.title.toLowerCase().includes(q);
          const matchFile = m.filename.toLowerCase().includes(q);
          const matchYear = m.year ? String(m.year).includes(q) : false;
          if (!matchTitle && !matchFile && !matchYear) return false;
        }

        const isMkv = m.filename.toLowerCase().endsWith('.mkv');
        const hasHls =
          activeHlsMap.has(m.filename.toLowerCase()) ||
          activeHlsMap.has((m.filename.split(/[\/\\]/).pop() ?? '').toLowerCase());

        switch (activeFilter) {
          case 'hls':
            return isMkv || hasHls;
          case 'direct':
            return !isMkv;
          case 'watched':
            return (m.percent ?? 0) > 0;
          case 'unwatched':
            return (m.percent ?? 0) === 0;
          default:
            return true;
        }
      })
      .sort((a, b) => {
        if (sortBy === 'year') {
          return (b.year ?? 0) - (a.year ?? 0);
        }
        if (sortBy === 'recent') {
          return (b.updated_at || '').localeCompare(a.updated_at || '');
        }
        return a.title.localeCompare(b.title);
      });
  }, [movies, searchQuery, activeFilter, sortBy, activeHlsMap]);

  const handleVerifyPin = async (candidatePin: string) => {
    setPinModalError(null);
    try {
      const res = await fetch('/api/admin/verify', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pin: candidatePin }),
      });
      const data = await res.json();
      if (res.ok && data.success) {
        setAdminPin(candidatePin);
        setIsPinUnlocked(true);
        sessionStorage.setItem('ms_admin_pin', candidatePin);
        sessionStorage.setItem('ms_admin_unlocked', 'true');
        setPinModalOpen(false);
        setPinInputValue('');
        setFeedback('Admin mode unlocked successfully!');
      } else {
        setPinModalError(data.error || 'Incorrect Admin PIN');
      }
    } catch {
      setPinModalError('Failed to verify Admin PIN');
    }
  };

  const onUpdatePolicy = async (newPolicy: string) => {
    if (!isAdmin) {
      setPinModalOpen(true);
      return;
    }
    setBusy(true);
    setFeedback(null);
    try {
      const res = await fetch('/api/storage/settings', {
        method: 'POST',
        headers: getAdminHeaders(),
        body: JSON.stringify({ retention_policy: newPolicy }),
      });
      if (res.ok) {
        setFeedback(`Retention policy updated to ${newPolicy}`);
        await loadData();
      } else {
        setError('Failed to update retention policy. Admin privileges required.');
      }
    } catch {
      setError('Failed to update retention policy');
    } finally {
      setBusy(false);
    }
  };

  const onPurgeOrphans = async () => {
    if (!isAdmin) {
      setPinModalOpen(true);
      return;
    }
    if (!confirm('Purge all verified orphaned transcode caches? This cannot be undone.')) return;
    setBusy(true);
    setFeedback(null);
    try {
      const res = await fetch('/api/storage/purge-orphans', {
        method: 'POST',
        headers: getAdminHeaders(),
      });
      if (res.ok) {
        setFeedback('Successfully purged orphaned cache directories!');
        await loadData();
      } else {
        setError('Purge operation failed. Admin privileges required.');
      }
    } catch {
      setError('Purge operation failed');
    } finally {
      setBusy(false);
    }
  };

  const onTriggerScan = async () => {
    setScanning(true);
    setFeedback(null);
    setError(null);
    try {
      const res = await fetch('/api/scan', { method: 'POST' });
      if (res.ok) {
        setFeedback('Library scan started! Refreshing files and metadata...');
        setTimeout(() => {
          void loadData();
        }, 3000);
      } else {
        setError('Failed to trigger scan');
      }
    } catch {
      setError('Failed to trigger scan');
    } finally {
      setScanning(false);
    }
  };

  const onArchiveMovie = async (movie: MovieItem) => {
    if (!isAdmin) {
      setPinModalOpen(true);
      return;
    }

    const confirmed = confirm(
      `Move original MKV file for "${movie.title}" to cold archive (D:\\Flicks\\.archive)?\n\n` +
      `The fast SSD HLS stream cache will remain active so you can continue streaming without interruption.`
    );
    if (!confirmed) return;

    setBusy(true);
    setFeedback(null);
    setError(null);
    try {
      const res = await fetch(`/api/storage/archive/${encodeURIComponent(movie.filename)}`, {
        method: 'POST',
        headers: getAdminHeaders(),
      });
      const data = await res.json();
      if (res.ok && data.success) {
        setFeedback(`Successfully moved "${movie.title}" to .archive storage.`);
        await loadData();
      } else {
        setError(data.error || data.result?.message || 'Failed to archive media source');
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Network error during archive');
    } finally {
      setBusy(false);
    }
  };

  const onConfirmDelete = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    setError(null);
    try {
      const candidatePin = modalPinInput || adminPin;
      const headers = getAdminHeaders(candidatePin);

      const res = await fetch(`/api/media/${encodeURIComponent(deleteTarget.filename)}`, {
        method: 'DELETE',
        headers,
      });
      const data = await res.json();
      if (res.ok && data.success) {
        if (candidatePin && !isPinUnlocked) {
          setAdminPin(candidatePin);
          setIsPinUnlocked(true);
          sessionStorage.setItem('ms_admin_pin', candidatePin);
          sessionStorage.setItem('ms_admin_unlocked', 'true');
        }
        setFeedback(`Permanently deleted and purged "${deleteTarget.title}".`);
        const purgedFilename = deleteTarget.filename;
        setDeleteTarget(null);
        setModalPinInput('');
        setMovies((prev) => prev.filter((m) => m.filename !== purgedFilename));
        await loadData();
      } else {
        setError(data.error || 'Failed to delete media file. Administrator privileges required.');
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Network error during delete');
    } finally {
      setDeleting(false);
    }
  };

  useEffect(() => {
    if (!deleteTarget && !pinModalOpen) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (deleteTarget && !deleting) setDeleteTarget(null);
        if (pinModalOpen) setPinModalOpen(false);
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [deleteTarget, pinModalOpen, deleting]);

  return (
    <div className="mx-auto max-w-5xl space-y-8 animate-fade-in pb-16">
      {/* Header Profile Section */}
      <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-4">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
          <div>
            <div className="flex items-center gap-2.5">
              <span className="flex h-9 w-9 items-center justify-center rounded-2xl bg-amber-500/15 text-amber-400 border border-amber-500/30">
                <Icon name="folder" size={18} />
              </span>
              <h1 className="text-2xl font-bold tracking-tight text-white">
                Library &amp; Storage Manager
              </h1>
            </div>
            <p className="mt-1 text-sm text-white/60">
              Manage your media inventory, delete or archive titles, inspect storage pools, and configure retention policies.
            </p>
          </div>

          <div className="flex flex-wrap items-center gap-2 self-start sm:self-auto">
            {/* Admin Verification Badge / Button */}
            {isAdmin ? (
              <span
                className="flex items-center gap-1.5 rounded-full border border-emerald-500/40 bg-emerald-500/10 px-3.5 py-2 text-xs font-semibold text-emerald-300 shadow-sm"
                title={email ? `Signed in as Admin (${email})` : 'Admin unlocked with PIN'}
              >
                <Icon name="shield" size={13} />
                <span>Admin Verified</span>
              </span>
            ) : (
              <button
                type="button"
                onClick={() => setPinModalOpen(true)}
                className="card-ring rounded-full border border-white/20 bg-white/5 hover:bg-white/10 px-3.5 py-2 text-xs font-semibold text-white/80 hover:text-white transition flex items-center gap-1.5 cursor-pointer"
                title="Unlock administrator controls with Admin PIN"
              >
                <Icon name="shield" size={13} />
                <span>Unlock Admin</span>
              </button>
            )}

            <button
              type="button"
              disabled={scanning}
              onClick={() => void onTriggerScan()}
              className="card-ring rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 hover:text-white transition flex items-center gap-1.5 cursor-pointer disabled:opacity-40"
              title="Rescan media folders and refresh metadata"
            >
              <Icon name="refresh" className={scanning ? 'animate-spin' : ''} size={13} />
              <span>{scanning ? 'Scanning…' : '↻ Scan Library'}</span>
            </button>

            <NavLink
              to="/"
              className="card-ring rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 hover:text-white transition"
            >
              ← Back to Library
            </NavLink>
          </div>
        </div>

        {/* Storage Pool Vitals Bar */}
        {auditData?.storage ? (
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
              {auditData.storage.drives?.map((d) => (
                <span key={d.drive} className="text-white/50">
                  {d.drive} {d.free_str} free ({d.percent}%)
                </span>
              ))}
              <span className="font-semibold text-white/70">{auditData.storage.percent ?? 0}% Allocated</span>
            </div>
          </div>
        ) : null}
      </section>

      {/* Messages */}
      {feedback ? (
        <div className="rounded-2xl border border-emerald-500/30 bg-emerald-500/10 p-4 text-xs font-medium text-emerald-300 animate-fade-in flex items-center justify-between">
          <span>✓ {feedback}</span>
          <button type="button" onClick={() => setFeedback(null)} className="text-emerald-400 hover:text-white">✕</button>
        </div>
      ) : null}

      {error ? (
        <div className="rounded-2xl border border-rose-500/30 bg-rose-500/10 p-4 text-xs font-medium text-rose-300 animate-fade-in flex items-center justify-between">
          <span>⚠️ {error}</span>
          <button type="button" onClick={() => setError(null)} className="text-rose-400 hover:text-white">✕</button>
        </div>
      ) : null}

      {/* Library Media Inventory & Management Section */}
      <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b border-white/10 pb-5">
          <div className="flex items-center gap-2.5">
            <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-brand-500/15 text-brand-400 border border-brand-500/30">
              <Icon name="video" size={18} />
            </div>
            <div>
              <h2 className="text-xl font-bold text-white flex items-center gap-2">
                Media Inventory
                <span className="rounded-full bg-white/10 px-2.5 py-0.5 text-xs font-normal text-white/60">
                  {filteredMovies.length} of {movies.length}
                </span>
              </h2>
              <p className="text-xs text-white/50">
                Play, inspect details, archive cold originals, or permanently delete titles
              </p>
            </div>
          </div>

          {/* Quick Stats Summary */}
          <div className="flex items-center gap-3 text-xs text-white/50">
            <span className="flex items-center gap-1.5">
              <span className="h-2 w-2 rounded-full bg-emerald-400" />
              {activeHlsMap.size} HLS Cached
            </span>
            <span className="flex items-center gap-1.5">
              <span className="h-2 w-2 rounded-full bg-blue-400" />
              {movies.filter((m) => !m.filename.toLowerCase().endsWith('.mkv')).length} Direct Play
            </span>
          </div>
        </div>

        {/* Filter & Search Toolbar */}
        <div className="flex flex-col sm:flex-row gap-3 items-stretch sm:items-center justify-between">
          {/* Search Box */}
          <div className="relative flex-1">
            <span className="absolute inset-y-0 left-3.5 flex items-center text-white/30 pointer-events-none">
              <Icon name="search" size={14} />
            </span>
            <input
              type="text"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder="Filter by title, filename, or year…"
              className="w-full rounded-2xl border border-white/15 bg-obsidian-900/80 py-2.5 pl-9 pr-8 text-xs text-white placeholder-white/40 focus:border-brand-500 focus:outline-none transition"
            />
            {searchQuery ? (
              <button
                type="button"
                onClick={() => setSearchQuery('')}
                className="absolute inset-y-0 right-3 flex items-center text-white/40 hover:text-white"
                title="Clear search"
              >
                ✕
              </button>
            ) : null}
          </div>

          {/* Category Chips */}
          <div className="flex items-center gap-1.5 overflow-x-auto pb-1 sm:pb-0 scrollbar-none">
            {[
              { id: 'all', label: `All (${movies.length})` },
              { id: 'hls', label: 'HLS / MKV' },
              { id: 'direct', label: 'Direct Play' },
              { id: 'watched', label: 'In Progress' },
              { id: 'unwatched', label: 'Unwatched' },
            ].map((chip) => (
              <button
                key={chip.id}
                type="button"
                onClick={() => setActiveFilter(chip.id as FilterCategory)}
                className={`rounded-full px-3 py-1.5 text-xs font-medium whitespace-nowrap transition cursor-pointer ${
                  activeFilter === chip.id
                    ? 'bg-brand-500 text-white shadow-sm shadow-brand-500/30'
                    : 'bg-white/5 text-white/60 hover:bg-white/10 hover:text-white border border-white/10'
                }`}
              >
                {chip.label}
              </button>
            ))}
          </div>

          {/* Sort Selector */}
          <div className="flex items-center gap-1.5 shrink-0">
            <span className="text-[11px] text-white/40">Sort:</span>
            <select
              value={sortBy}
              onChange={(e) => setSortBy(e.target.value as SortField)}
              className="rounded-xl border border-white/15 bg-obsidian-900/90 px-2.5 py-1.5 text-xs text-white/80 focus:border-brand-500 focus:outline-none"
            >
              <option value="title">Title (A–Z)</option>
              <option value="year">Year (Newest)</option>
              <option value="recent">Recently Watched</option>
            </select>
          </div>
        </div>

        {/* Media Items List */}
        {loading ? (
          <div className="py-12 flex flex-col items-center justify-center space-y-3">
            <div className="h-7 w-7 rounded-full border-2 border-white/10 border-t-brand-500 animate-spin" />
            <p className="text-xs text-white/50">Loading library media inventory…</p>
          </div>
        ) : filteredMovies.length === 0 ? (
          <div className="rounded-2xl border border-white/10 bg-obsidian-900/40 p-8 text-center space-y-2">
            <p className="text-sm font-semibold text-white/70">No matching media files found</p>
            <p className="text-xs text-white/40">
              {searchQuery ? `No files matching "${searchQuery}".` : 'No media files in configured storage roots.'}
            </p>
            {searchQuery ? (
              <button
                type="button"
                onClick={() => { setSearchQuery(''); setActiveFilter('all'); }}
                className="mt-2 rounded-full border border-white/15 bg-white/5 px-4 py-1.5 text-xs text-white/80 hover:bg-white/10 transition"
              >
                Reset Filters
              </button>
            ) : null}
          </div>
        ) : (
          <div className="space-y-3">
            {filteredMovies.map((m) => {
              const ext = m.filename.split('.').pop()?.toUpperCase() ?? 'VIDEO';
              const isMkv = m.filename.toLowerCase().endsWith('.mkv');
              const hlsItem =
                activeHlsMap.get(m.filename.toLowerCase()) ||
                activeHlsMap.get((m.filename.split(/[\/\\]/).pop() ?? '').toLowerCase());
              const hasHlsCache = Boolean(hlsItem);
              const pUrl = posterUrl(m.poster);
              const isWatched = (m.percent ?? 0) > 0;

              return (
                <div
                  key={m.filename}
                  className="rounded-2xl border border-white/10 bg-obsidian-900/70 p-4 sm:p-4.5 hover:border-white/20 hover:bg-obsidian-900/90 transition flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 group"
                >
                  {/* Poster Thumbnail + Titles */}
                  <div className="flex items-center gap-3.5 min-w-0 flex-1">
                    <div className="h-16 w-11 sm:h-18 sm:w-12 rounded-xl overflow-hidden bg-white/5 border border-white/10 shrink-0 relative shadow-md">
                      {pUrl ? (
                        <img
                          src={pUrl}
                          alt={m.title}
                          className="h-full w-full object-cover"
                          loading="lazy"
                        />
                      ) : (
                        <div className="h-full w-full flex items-center justify-center text-white/30 text-lg">
                          🎬
                        </div>
                      )}
                    </div>

                    <div className="min-w-0 space-y-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <NavLink
                          to={`/movie/${encodeURIComponent(m.filename)}`}
                          className="font-bold text-sm sm:text-base text-white hover:text-brand-400 transition truncate"
                          title="View movie details"
                        >
                          {m.title}
                        </NavLink>
                        {m.year ? (
                          <span className="text-xs text-white/50">({m.year})</span>
                        ) : null}

                        {/* Format & Stream Badges */}
                        <span className="rounded-md bg-white/10 border border-white/15 px-1.5 py-0.5 text-[10px] font-mono text-white/70 uppercase">
                          {ext}
                        </span>

                        {hasHlsCache ? (
                          <span className="rounded-md bg-emerald-500/15 border border-emerald-500/30 px-1.5 py-0.5 text-[10px] font-semibold text-emerald-300 flex items-center gap-1">
                            <span className="h-1.5 w-1.5 rounded-full bg-emerald-400" />
                            HLS Cached
                            {hlsItem?.size_bytes ? ` (${formatBytes(hlsItem.size_bytes)})` : ''}
                          </span>
                        ) : isMkv ? (
                          <span className="rounded-md bg-amber-500/15 border border-amber-500/30 px-1.5 py-0.5 text-[10px] font-semibold text-amber-300">
                            ⚙ On-Demand HLS
                          </span>
                        ) : (
                          <span className="rounded-md bg-blue-500/15 border border-blue-500/30 px-1.5 py-0.5 text-[10px] font-semibold text-blue-300">
                            ✨ Direct Stream
                          </span>
                        )}

                        {isWatched ? (
                          <span className="rounded-md bg-brand-500/15 border border-brand-500/30 px-1.5 py-0.5 text-[10px] font-semibold text-brand-300">
                            Watched: {Math.round(m.percent ?? 0)}%
                          </span>
                        ) : null}
                      </div>

                      <p className="font-mono text-[11px] text-white/40 truncate select-all" title={m.filename}>
                        {m.filename}
                      </p>

                      {m.runtime ? (
                        <p className="text-[11px] text-white/40">
                          Runtime: {m.runtime} min {m.rating ? `· Rating: ⭐ ${m.rating.toFixed(1)}` : ''}
                        </p>
                      ) : null}
                    </div>
                  </div>

                  {/* Actions Toolbar */}
                  <div className="flex flex-wrap items-center gap-2 self-end sm:self-auto shrink-0 pt-2 sm:pt-0 border-t sm:border-t-0 border-white/5 w-full sm:w-auto justify-end">
                    {/* Watch Button */}
                    <NavLink
                      to={`/watch/${encodeURIComponent(m.filename)}`}
                      className="rounded-full bg-white/10 hover:bg-brand-500 text-white/90 hover:text-white px-3.5 py-1.5 text-xs font-semibold transition flex items-center gap-1.5 shadow-sm"
                      title="Play movie in cinema player"
                    >
                      <Icon name="play" size={11} />
                      <span>Watch</span>
                    </NavLink>

                    {/* Details Button */}
                    <NavLink
                      to={`/movie/${encodeURIComponent(m.filename)}`}
                      className="rounded-full border border-white/15 bg-white/5 hover:bg-white/10 text-white/75 hover:text-white px-3 py-1.5 text-xs font-semibold transition flex items-center gap-1.5"
                      title="View cast, subtitles, and full media specifications"
                    >
                      <Icon name="info" size={12} />
                      <span>Details</span>
                    </NavLink>

                    {/* Archive Source Button (for MKV with HLS cache) */}
                    {isMkv && hasHlsCache ? (
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => void onArchiveMovie(m)}
                        className="rounded-full border border-amber-500/30 bg-amber-500/10 hover:bg-amber-500/25 text-amber-300 px-3 py-1.5 text-xs font-semibold transition flex items-center gap-1.5 cursor-pointer disabled:opacity-30"
                        title="Move original MKV file to .archive cold storage to save space while keeping HLS stream cache"
                      >
                        <Icon name="archive" size={12} />
                        <span>Archive</span>
                      </button>
                    ) : null}

                    {/* Delete & Purge Button */}
                    <button
                      type="button"
                      disabled={busy || deleting}
                      onClick={() => {
                        setDeleteTarget(m);
                        setModalPinInput(adminPin);
                      }}
                      className="rounded-full border border-rose-500/30 bg-rose-500/10 hover:bg-rose-500/25 text-rose-300 hover:text-rose-200 px-3 py-1.5 text-xs font-semibold transition flex items-center gap-1.5 cursor-pointer disabled:opacity-30"
                      title="Permanently delete movie and purge all transcode caches, subtitles, and database records"
                    >
                      <Icon name="trash" size={12} />
                      <span>Delete</span>
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </section>

      {/* Retention Policy Card */}
      <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-brand-500/15 text-brand-400 border border-brand-500/30">
            <Icon name="sparkle" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Post-Transcode Retention Policy</h2>
            <p className="text-xs text-white/50">Controls how raw files and transcode caches are managed after playback</p>
          </div>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3.5">
          {[
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
          ].map((pol) => {
            const isSelected = settings?.retention_policy === pol.id;
            return (
              <button
                key={pol.id}
                type="button"
                disabled={busy}
                onClick={() => void onUpdatePolicy(pol.id)}
                className={`rounded-2xl border p-4.5 text-left transition space-y-2 cursor-pointer ${
                  isSelected
                    ? 'border-brand-500/80 bg-brand-500/15 ring-2 ring-brand-500/30'
                    : 'border-white/10 bg-obsidian-900/60 hover:border-white/20 hover:bg-white/[0.04]'
                }`}
              >
                <div className="flex items-center justify-between">
                  <span className={`text-xs font-bold uppercase tracking-wider ${isSelected ? 'text-brand-300' : 'text-white/60'}`}>
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

      {/* Orphaned Cache Audit & Cleaner */}
      <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
          <div className="flex items-center gap-2.5">
            <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-rose-500/15 text-rose-400 border border-rose-500/30">
              <Icon name="disc" size={18} />
            </div>
            <div>
              <h2 className="text-xl font-bold text-white">Orphaned Cache Audit</h2>
              <p className="text-xs text-white/50">Identify and reclaim disk space from abandoned transcode folders</p>
            </div>
          </div>

          <button
            type="button"
            disabled={busy || (auditData?.audit.total_orphaned_dirs ?? 0) === 0}
            onClick={() => void onPurgeOrphans()}
            className="card-ring rounded-full bg-rose-500/20 border border-rose-500/40 px-5 py-2 text-xs font-semibold text-rose-200 hover:bg-rose-500/30 transition disabled:opacity-30 disabled:hover:bg-rose-500/20"
          >
            {busy ? 'Purging…' : 'Purge Orphaned Caches'}
          </button>
        </div>

        <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-5 flex flex-wrap items-center justify-between gap-4 text-xs">
          <div>
            <span className="block text-white/40">Orphaned Directories</span>
            <span className="text-lg font-bold text-white">
              {auditData?.audit.total_orphaned_dirs ?? 0} folders
            </span>
          </div>
          <div>
            <span className="block text-white/40">Reclaimable Space</span>
            <span className="text-lg font-bold text-emerald-400">
              {auditData?.audit.total_orphaned_bytes
                ? formatBytes(auditData.audit.total_orphaned_bytes)
                : '0 MB'}
            </span>
          </div>
          <div>
            <span className="block text-white/40">Cache Audit Status</span>
            <span className="text-emerald-400 font-semibold">
              {(auditData?.audit.total_orphaned_dirs ?? 0) === 0 ? '✓ Healthy & Synced' : 'Action Available'}
            </span>
          </div>
        </div>
      </section>

      {/* Delete & Purge Confirmation Modal */}
      {deleteTarget && typeof document !== 'undefined'
        ? createPortal(
            <div
              role="dialog"
              aria-modal="true"
              aria-labelledby="purgeModalTitle"
              className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-md overflow-y-auto animate-overlay-fade"
            >
              <div
                className="relative w-full max-w-md my-auto rounded-3xl border border-rose-500/40 bg-obsidian-950 p-6 sm:p-7 shadow-2xl space-y-5 animate-scale-in"
                onClick={(e) => e.stopPropagation()}
              >
                {/* Modal Header */}
                <div className="flex items-start justify-between gap-3">
                  <div className="flex items-center gap-3">
                    <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-rose-500/20 text-rose-400 border border-rose-500/40 shrink-0">
                      <Icon name="trash" size={20} />
                    </span>
                    <div>
                      <h3 id="purgeModalTitle" className="text-lg font-bold text-white">
                        Permanently Delete &amp; Purge?
                      </h3>
                      <p className="text-xs text-rose-300/80 font-medium">This action cannot be undone</p>
                    </div>
                  </div>
                  <button
                    type="button"
                    disabled={deleting}
                    onClick={() => setDeleteTarget(null)}
                    className="rounded-full p-1.5 text-white/50 hover:bg-white/10 hover:text-white transition cursor-pointer"
                    aria-label="Close dialog"
                  >
                    ✕
                  </button>
                </div>

                {/* Target Media Card */}
                <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-3.5 flex items-center gap-3">
                  <div className="h-14 w-10 rounded-lg overflow-hidden bg-white/5 border border-white/10 shrink-0">
                    {deleteTarget.poster ? (
                      <img
                        src={posterUrl(deleteTarget.poster) ?? ''}
                        alt={deleteTarget.title}
                        className="h-full w-full object-cover"
                      />
                    ) : (
                      <div className="h-full w-full flex items-center justify-center text-xs text-white/30">
                        🎬
                      </div>
                    )}
                  </div>
                  <div className="min-w-0 flex-1">
                    <p className="font-bold text-sm text-white truncate">
                      {deleteTarget.title} {deleteTarget.year ? `(${deleteTarget.year})` : ''}
                    </p>
                    <p className="font-mono text-[11px] text-white/40 truncate">{deleteTarget.filename}</p>
                  </div>
                </div>

                {/* What will be purged checklist */}
                <div className="rounded-2xl border border-rose-500/20 bg-rose-500/5 p-4 space-y-2 text-xs">
                  <span className="font-bold text-rose-300 block">Associated data that will be completely wiped:</span>
                  <ul className="space-y-1.5 text-white/70">
                    <li className="flex items-center gap-2">
                      <span className="text-rose-400">✕</span>
                      <span>Source video file on disk</span>
                    </li>
                    <li className="flex items-center gap-2">
                      <span className="text-rose-400">✕</span>
                      <span>HLS transcode cache chunks &amp; live seek thumbnails</span>
                    </li>
                    <li className="flex items-center gap-2">
                      <span className="text-rose-400">✕</span>
                      <span>Sidecar subtitles &amp; TMDb metadata records</span>
                    </li>
                    <li className="flex items-center gap-2">
                      <span className="text-rose-400">✕</span>
                      <span>Client watch progress and resume points</span>
                    </li>
                  </ul>
                </div>

                {/* Admin PIN input if not yet unlocked */}
                {!isAdmin ? (
                  <div className="rounded-2xl border border-rose-500/30 bg-rose-500/10 p-4 space-y-2">
                    <label className="text-xs font-bold text-rose-300 flex items-center gap-1.5">
                      <Icon name="shield" size={13} />
                      Admin PIN Required (6361)
                    </label>
                    <input
                      type="password"
                      maxLength={8}
                      value={modalPinInput}
                      onChange={(e) => setModalPinInput(e.target.value)}
                      placeholder="Enter 4-digit PIN…"
                      className="w-full rounded-xl border border-rose-500/40 bg-obsidian-900/90 px-3.5 py-2 text-sm text-white placeholder-white/30 focus:border-rose-400 focus:outline-none"
                    />
                    <p className="text-[11px] text-white/50">
                      Authorized as {email || 'Administrator'} or enter your Admin PIN to authorize deletion.
                    </p>
                  </div>
                ) : null}

                {/* Modal Actions */}
                <div className="flex items-center justify-end gap-3 pt-2">
                  <button
                    type="button"
                    disabled={deleting}
                    onClick={() => setDeleteTarget(null)}
                    className="rounded-full border border-white/15 bg-white/5 hover:bg-white/10 text-white/80 px-4 py-2 text-xs font-semibold transition cursor-pointer"
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    disabled={deleting || (!isAdmin && !modalPinInput)}
                    onClick={() => void onConfirmDelete()}
                    className="rounded-full bg-rose-600 hover:bg-rose-500 text-white px-5 py-2 text-xs font-bold transition flex items-center gap-2 shadow-lg shadow-rose-600/30 cursor-pointer disabled:opacity-40"
                  >
                    {deleting ? (
                      <>
                        <span className="h-3 w-3 rounded-full border-2 border-white/20 border-t-white animate-spin" />
                        <span>Purging File…</span>
                      </>
                    ) : (
                      <>
                        <Icon name="trash" size={13} />
                        <span>Yes, Delete &amp; Purge Everything</span>
                      </>
                    )}
                  </button>
                </div>
              </div>
            </div>,
            document.body
          )
        : null}

      {/* Standalone Admin PIN Unlock Dialog */}
      {pinModalOpen && typeof document !== 'undefined'
        ? createPortal(
            <div
              role="dialog"
              aria-modal="true"
              className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-md overflow-y-auto animate-overlay-fade"
              onClick={(e) => {
                if (e.target === e.currentTarget) setPinModalOpen(false);
              }}
            >
              <div
                className="relative w-full max-w-sm my-auto rounded-3xl border border-brand-500/40 bg-obsidian-950 p-6 shadow-2xl space-y-4 animate-scale-in"
                onClick={(e) => e.stopPropagation()}
              >
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2.5">
                    <span className="flex h-9 w-9 items-center justify-center rounded-2xl bg-brand-500/20 text-brand-400 border border-brand-500/40">
                      <Icon name="shield" size={18} />
                    </span>
                    <div>
                      <h3 className="font-bold text-white text-base">Unlock Admin Mode</h3>
                      <p className="text-xs text-white/50">Enter your 4-digit PIN</p>
                    </div>
                  </div>
                  <button
                    type="button"
                    onClick={() => setPinModalOpen(false)}
                    className="text-white/40 hover:text-white cursor-pointer"
                  >
                    ✕
                  </button>
                </div>

                {pinModalError ? (
                  <div className="rounded-xl border border-rose-500/30 bg-rose-500/10 p-3 text-xs text-rose-300">
                    ⚠️ {pinModalError}
                  </div>
                ) : null}

                <form
                  onSubmit={(e) => {
                    e.preventDefault();
                    void handleVerifyPin(pinInputValue);
                  }}
                  className="space-y-4"
                >
                  <input
                    type="password"
                    maxLength={8}
                    autoFocus
                    value={pinInputValue}
                    onChange={(e) => setPinInputValue(e.target.value)}
                    placeholder="Admin PIN…"
                    className="w-full text-center tracking-widest text-lg rounded-xl border border-white/20 bg-obsidian-900 py-2.5 px-4 text-white focus:border-brand-500 focus:outline-none"
                  />

                  <div className="flex items-center justify-end gap-2.5">
                    <button
                      type="button"
                      onClick={() => setPinModalOpen(false)}
                      className="rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 cursor-pointer"
                    >
                      Cancel
                    </button>
                    <button
                      type="submit"
                      disabled={!pinInputValue}
                      className="rounded-full brand-gradient px-5 py-2 text-xs font-bold text-white shadow-md disabled:opacity-40 cursor-pointer"
                    >
                      Unlock
                    </button>
                  </div>
                </form>
              </div>
            </div>,
            document.body
          )
        : null}
    </div>
  );
}

export default ManagePage;
