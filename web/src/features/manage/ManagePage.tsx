import { useCallback, useEffect, useMemo, useState } from 'react';
import { NavLink } from 'react-router';
import { useAuth } from '../../auth/AuthProvider';
import { Icon } from '../../components/icons';
import {
  archiveMovieMedia,
  deleteMovieMedia,
  fetchManageMovies,
  fetchStorageAudit,
  fetchStorageSettings,
  purgeOrphanedCaches,
  triggerLibraryScan,
  updateStoragePolicy,
  verifyAdminPin,
  type MovieItem,
  type StorageAuditData,
  type StorageSettings,
} from '../../lib/api/manage';
import { AdminAccessGate } from './components/AdminAccessGate';
import { AdminPinModal } from './components/AdminPinModal';
import { DeleteConfirmationModal } from './components/DeleteConfirmationModal';
import {
  InventoryToolbar,
  type FilterCategory,
  type SortField,
} from './components/InventoryToolbar';
import { InventoryList } from './components/InventoryList';
import { OrphanedCacheAudit } from './components/OrphanedCacheAudit';
import { RetentionPolicyCard } from './components/RetentionPolicyCard';
import { StoragePoolHud } from './components/StoragePoolHud';

export function ManagePage() {
  const { role, email, authenticated, signIn } = useAuth();
  const [auditData, setAuditData] = useState<StorageAuditData | null>(null);
  const [auditLoading, setAuditLoading] = useState(true);
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

  const loadData = useCallback(async () => {
    // 1. Fetch movies immediately so inventory renders in < 100ms
    void fetchManageMovies()
      .then((items) => {
        setMovies(items);
      })
      .catch((err) => {
        setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        setLoading(false);
      });

    // If not admin, do not crawl settings or storage audit
    if (!isAdmin) {
      setAuditLoading(false);
      return;
    }

    const effectivePin = adminPin || sessionStorage.getItem('ms_admin_pin') || '';

    // 2. Fetch storage settings in parallel with deadline
    void fetchStorageSettings(effectivePin)
      .then((data) => setSettings(data))
      .catch(() => {});

    // 3. Fetch storage audit in background (probes media roots)
    setAuditLoading(true);
    void fetchStorageAudit(effectivePin)
      .then((data) => setAuditData(data))
      .catch(() => {})
      .finally(() => {
        setAuditLoading(false);
      });
  }, [isAdmin, adminPin]);

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

        const isMkv = m.filename.toLowerCase().endsWith('.mkv') || m.needs_transcode === true;
        const hasHls =
          m.hls_cached === true ||
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
      const data = await verifyAdminPin(candidatePin);
      if (data.success) {
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
      const res = await updateStoragePolicy(newPolicy, adminPin);
      if (res.success) {
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
      const res = await purgeOrphanedCaches(adminPin);
      if (res.success) {
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
      const res = await triggerLibraryScan(adminPin);
      if (res.success) {
        setFeedback('Library scan started! Refreshing files and metadata...');
        setTimeout(() => {
          void loadData();
        }, 3000);
      } else {
        setError('Failed to trigger scan. Administrator verification required.');
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to trigger scan');
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
      `The fast SSD stream cache will remain active so you can continue streaming without interruption.`
    );
    if (!confirmed) return;

    setBusy(true);
    setFeedback(null);
    setError(null);
    try {
      const data = await archiveMovieMedia(movie.filename, adminPin);
      if (data.success) {
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
      const data = await deleteMovieMedia(deleteTarget.filename, candidatePin);
      if (data.success) {
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

  if (!isAdmin) {
    return (
      <>
        <AdminAccessGate
          authenticated={authenticated}
          onOpenPinModal={() => setPinModalOpen(true)}
          onSignIn={() => signIn()}
        />
        <AdminPinModal
          isOpen={pinModalOpen}
          pinValue={pinInputValue}
          error={pinModalError}
          onChangePin={setPinInputValue}
          onSubmit={() => void handleVerifyPin(pinInputValue)}
          onClose={() => setPinModalOpen(false)}
        />
      </>
    );
  }

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
        <StoragePoolHud auditData={auditData} loading={auditLoading} />
      </section>

      {/* Messages */}
      {feedback ? (
        <div className="rounded-2xl border border-emerald-500/30 bg-emerald-500/10 p-4 text-xs font-medium text-emerald-300 animate-fade-in flex items-center justify-between">
          <span>✓ {feedback}</span>
          <button type="button" onClick={() => setFeedback(null)} className="text-emerald-400 hover:text-white cursor-pointer">✕</button>
        </div>
      ) : null}

      {error ? (
        <div className="rounded-2xl border border-rose-500/30 bg-rose-500/10 p-4 text-xs font-medium text-rose-300 animate-fade-in flex items-center justify-between">
          <span>⚠️ {error}</span>
          <button type="button" onClick={() => setError(null)} className="text-rose-400 hover:text-white cursor-pointer">✕</button>
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
              {activeHlsMap.size > 0
                ? `${activeHlsMap.size} Stream Ready`
                : `${movies.filter((m) => m.hls_cached).length} Stream Ready`}
              {auditLoading ? (
                <span className="text-[10px] text-white/35">(auditing…)</span>
              ) : null}
            </span>
            <span className="flex items-center gap-1.5">
              <span className="h-2 w-2 rounded-full bg-blue-400" />
              {movies.filter((m) => !m.filename.toLowerCase().endsWith('.mkv') && !m.needs_transcode).length} Direct Play
            </span>
          </div>
        </div>

        {/* Filter & Search Toolbar */}
        <InventoryToolbar
          searchQuery={searchQuery}
          onSearchChange={setSearchQuery}
          activeFilter={activeFilter}
          onFilterChange={setActiveFilter}
          sortBy={sortBy}
          onSortChange={setSortBy}
          totalCount={movies.length}
        />

        {/* Media Items List */}
        <InventoryList
          movies={filteredMovies}
          loading={loading}
          auditLoading={auditLoading}
          activeHlsMap={activeHlsMap}
          searchQuery={searchQuery}
          busy={busy}
          deleting={deleting}
          onResetFilters={() => {
            setSearchQuery('');
            setActiveFilter('all');
          }}
          onArchiveMovie={(m) => void onArchiveMovie(m)}
          onDeleteClick={(m) => {
            setDeleteTarget(m);
            setModalPinInput(adminPin);
          }}
        />
      </section>

      {/* Retention Policy Card */}
      <RetentionPolicyCard
        settings={settings}
        busy={busy}
        onUpdatePolicy={(pol) => void onUpdatePolicy(pol)}
      />

      {/* Orphaned Cache Audit & Cleaner */}
      <OrphanedCacheAudit
        auditData={auditData}
        busy={busy}
        onPurgeOrphans={() => void onPurgeOrphans()}
      />

      {/* Delete & Purge Confirmation Modal */}
      <DeleteConfirmationModal
        deleteTarget={deleteTarget}
        deleting={deleting}
        isAdmin={isAdmin}
        adminPin={adminPin}
        modalPinInput={modalPinInput}
        email={email}
        onChangePinInput={setModalPinInput}
        onConfirmDelete={() => void onConfirmDelete()}
        onClose={() => setDeleteTarget(null)}
      />

      {/* Standalone Admin PIN Unlock Dialog */}
      <AdminPinModal
        isOpen={pinModalOpen}
        pinValue={pinInputValue}
        error={pinModalError}
        onChangePin={setPinInputValue}
        onSubmit={() => void handleVerifyPin(pinInputValue)}
        onClose={() => setPinModalOpen(false)}
      />
    </div>
  );
}

export default ManagePage;
