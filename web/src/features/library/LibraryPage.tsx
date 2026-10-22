import { useCallback, useMemo, useState } from 'react';
import { listMovies } from '../../lib/api/client';
import { getStoredAdminPin } from '../../lib/api/account';
import { verifyAdminPin } from '../../lib/api/manage';
import { useOptionalAuth } from '../../auth/AuthProvider';
import { useDeviceId } from '../../lib/useDeviceId';
import { StateMessage } from '../../components/StateMessage';
import { useAsync } from '../../lib/useAsync';
import { MovieGrid } from '../../components/MovieGrid';
import { AdminPinModal } from '../manage/components/AdminPinModal';
import { MediaUploadModal } from '../upload/MediaUploadModal';
import type { UploadSuccess } from '../upload/uploadApi';
import { HeroSpotlight } from './HeroSpotlight';
import { Icon } from '../../components/icons';

export function LibraryPage() {
  const deviceId = useDeviceId();
  const auth = useOptionalAuth();
  const role = auth?.role ?? null;

  const { data, error, loading, reload } = useAsync(
    (signal) => listMovies({ signal, deviceId }),
    [deviceId],
  );

  const movies = data?.movies ?? [];
  const watching = data?.watching ?? [];

  const [searchQuery, setSearchQuery] = useState('');
  const [selectedGenre, setSelectedGenre] = useState<string | null>(null);
  const [sortBy, setSortBy] = useState<'recent' | 'title' | 'rating' | 'year'>('recent');

  // Upload is admin-only. An admin session is enough; otherwise the PIN is
  // verified once, stored in sessionStorage, and sent as X-Admin-Pin.
  const [uploadOpen, setUploadOpen] = useState(false);
  const [adminPin, setAdminPin] = useState<string | null>(() => getStoredAdminPin());
  const [pinModalOpen, setPinModalOpen] = useState(false);
  const [pinValue, setPinValue] = useState('');
  const [pinError, setPinError] = useState<string | null>(null);
  const [pinBusy, setPinBusy] = useState(false);

  const handleUploadClick = () => {
    setPinError(null);
    setPinValue('');
    if (role !== 'admin' && !adminPin) {
      setPinModalOpen(true);
      return;
    }
    setUploadOpen(true);
  };

  const handleVerifyPin = async () => {
    if (pinBusy) return;
    const candidate = pinValue.trim();
    if (!candidate) {
      setPinError('Enter your Admin PIN.');
      return;
    }
    setPinBusy(true);
    setPinError(null);
    try {
      const data = await verifyAdminPin(candidate);
      if (data.success) {
        setAdminPin(candidate);
        try {
          sessionStorage.setItem('ms_admin_pin', candidate);
        } catch {
          // Storage can be unavailable; the in-memory PIN still works.
        }
        setPinModalOpen(false);
        setPinValue('');
        setUploadOpen(true);
      } else {
        setPinError(data.error || 'Incorrect Admin PIN.');
      }
    } catch {
      setPinError('Failed to verify the Admin PIN.');
    } finally {
      setPinBusy(false);
    }
  };

  const handleNeedPin = useCallback(() => {
    setUploadOpen(false);
    setPinError(null);
    setPinValue('');
    setPinModalOpen(true);
  }, []);

  const handleUploaded = useCallback(
    (_result: UploadSuccess) => {
      void reload();
    },
    [reload],
  );

  // Featured billboard candidate: prefer active watch or title with rich artwork
  const featured = useMemo(() => {
    if (movies.length === 0) return null;
    return (
      watching[0] ||
      movies.find((m) => Boolean(m.backdrop_path || (m.tmdb_id && m.overview))) ||
      null
    );
  }, [watching, movies]);

  // Unique genres across the library catalog
  const genres = useMemo(() => {
    const set = new Set<string>();
    for (const m of movies) {
      if (m.genres) {
        m.genres.split(',').forEach((g) => {
          const trimmed = g.trim();
          if (trimmed) set.add(trimmed);
        });
      }
    }
    return Array.from(set).sort();
  }, [movies]);

  // Filter and sort movies
  const filteredMovies = useMemo(() => {
    let result = [...movies];
    if (searchQuery.trim()) {
      const q = searchQuery.toLowerCase().trim();
      result = result.filter(
        (m) =>
          m.title.toLowerCase().includes(q) ||
          (m.year && String(m.year).includes(q)) ||
          (m.genres && m.genres.toLowerCase().includes(q)),
      );
    }
    if (selectedGenre) {
      result = result.filter((m) => m.genres && m.genres.includes(selectedGenre));
    }
    if (sortBy === 'title') {
      result.sort((a, b) => a.title.localeCompare(b.title));
    } else if (sortBy === 'rating') {
      result.sort((a, b) => (Number(b.rating) || 0) - (Number(a.rating) || 0));
    } else if (sortBy === 'year') {
      result.sort((a, b) => (Number(b.year) || 0) - (Number(a.year) || 0));
    }
    return result;
  }, [movies, searchQuery, selectedGenre, sortBy]);

  const hasActiveFilters = Boolean(searchQuery.trim() || selectedGenre || sortBy !== 'recent');

  return (
    <div className="space-y-8 animate-fade-in">
      <div className="flex flex-wrap items-center justify-end gap-2">
        <button
          type="button"
          onClick={handleUploadClick}
          className="inline-flex items-center gap-2 rounded-full brand-gradient px-4 py-2 text-xs font-bold text-white shadow-md transition hover:brightness-110 active:scale-[0.98]"
        >
          <Icon name="upload" size={14} />
          Upload Media
        </button>
      </div>

      {/* Cinematic Hero Billboard (only shown when catalog is populated and featured has artwork) */}
      {!loading && !error && featured && (featured.overview || featured.backdrop_path) && !hasActiveFilters ? (
        <HeroSpotlight movie={featured} hasTopBanner={false} />
      ) : null}

      {/* Interactive Search, Filter & Sort Bar */}
      {!loading && !error && movies.length > 0 ? (
        <div className="space-y-4">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            {/* Search Input */}
            <div className="relative flex-1 max-w-md">
              <div className="pointer-events-none absolute inset-y-0 left-0 flex items-center pl-3.5 text-white/40">
                <Icon name="search" size={16} />
              </div>
              <input
                type="text"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Search movies by title, year, genre..."
                aria-label="Search movies"
                className="w-full rounded-full border border-white/10 bg-obsidian-850 py-2.5 pl-10 pr-9 text-sm text-white placeholder-white/40 shadow-inner transition focus:border-brand-500/60 focus:bg-obsidian-800 focus:outline-none focus:ring-2 focus:ring-brand-500/20"
              />
              {searchQuery ? (
                <button
                  type="button"
                  onClick={() => setSearchQuery('')}
                  aria-label="Clear search"
                  className="absolute inset-y-0 right-0 flex items-center pr-3 text-white/40 hover:text-white"
                >
                  <Icon name="x" size={14} />
                </button>
              ) : null}
            </div>

            {/* Sort Selector & Results Badge */}
            <div className="flex items-center gap-3 self-end sm:self-auto">
              <span className="text-xs text-white/40 font-medium">
                {filteredMovies.length} {filteredMovies.length === 1 ? 'title' : 'titles'}
              </span>

              <div className="flex items-center gap-1.5 rounded-full border border-white/10 bg-obsidian-850 px-3 py-1.5 text-xs text-white/80">
                <Icon name="sort" size={13} className="text-white/40" />
                <label htmlFor="sort-select" className="sr-only">Sort by</label>
                <select
                  id="sort-select"
                  value={sortBy}
                  onChange={(e) => setSortBy(e.target.value as any)}
                  className="bg-transparent text-xs text-white focus:outline-none cursor-pointer pr-1"
                >
                  <option value="recent" className="bg-obsidian-900 text-white">Recently Added</option>
                  <option value="title" className="bg-obsidian-900 text-white">Title (A–Z)</option>
                  <option value="rating" className="bg-obsidian-900 text-white">Highest Rated</option>
                  <option value="year" className="bg-obsidian-900 text-white">Release Year</option>
                </select>
              </div>
            </div>
          </div>

          {/* Genre Filter Pills */}
          {genres.length > 0 ? (
            <div className="flex items-center gap-2 overflow-x-auto pb-1 scrollbar-none" role="tablist" aria-label="Genre filters">
              <button
                type="button"
                onClick={() => setSelectedGenre(null)}
                className={`rounded-full px-3.5 py-1 text-xs font-semibold transition ${
                  selectedGenre === null
                    ? 'bg-brand-500 text-white shadow-sm'
                    : 'bg-white/5 text-white/60 hover:bg-white/10 hover:text-white border border-white/5'
                }`}
              >
                All Genres
              </button>
              {genres.map((g) => (
                <button
                  key={g}
                  type="button"
                  onClick={() => setSelectedGenre(selectedGenre === g ? null : g)}
                  className={`rounded-full px-3.5 py-1 text-xs font-semibold whitespace-nowrap transition ${
                    selectedGenre === g
                      ? 'bg-brand-500 text-white shadow-sm'
                      : 'bg-white/5 text-white/60 hover:bg-white/10 hover:text-white border border-white/5'
                  }`}
                >
                  {g}
                </button>
              ))}
            </div>
          ) : null}
        </div>
      ) : null}

      {/*
        "Continue watching" only renders when there is something to continue
        and no search filter is actively narrowing the view.
      */}
      {watching.length > 0 && !hasActiveFilters ? (
        <MovieGrid movies={watching} title="Continue watching" />
      ) : null}

      <StateMessage
        loading={loading}
        error={error}
        empty={!loading && !error && movies.length === 0}
        emptyText="No movies found. Run a scan from the library page to populate the catalog."
        onRetry={reload}
      >
        {filteredMovies.length > 0 ? (
          <MovieGrid
            movies={filteredMovies}
            title={watching.length > 0 && !hasActiveFilters ? 'All movies' : 'Movies'}
          />
        ) : (
          <div className="rounded-2xl border border-white/10 bg-obsidian-850 p-10 text-center">
            <p className="text-base font-semibold text-white">No titles match &ldquo;{searchQuery}&rdquo;</p>
            <p className="mt-1 text-xs text-white/50">Try checking the spelling or resetting your genre and search filters.</p>
            <button
              type="button"
              onClick={() => {
                setSearchQuery('');
                setSelectedGenre(null);
                setSortBy('recent');
              }}
              className="mt-4 rounded-full bg-white/10 px-4 py-2 text-xs font-semibold text-white hover:bg-white/15"
            >
              Reset filters
            </button>
          </div>
        )}
      </StateMessage>

      <AdminPinModal
        isOpen={pinModalOpen}
        pinValue={pinValue}
        error={pinError}
        onChangePin={setPinValue}
        onSubmit={() => {
          void handleVerifyPin();
        }}
        onClose={() => {
          setPinModalOpen(false);
          setPinError(null);
        }}
      />
      <MediaUploadModal
        open={uploadOpen}
        onClose={() => setUploadOpen(false)}
        onUploaded={handleUploaded}
        onNeedPin={handleNeedPin}
        adminPin={adminPin}
      />
    </div>
  );
}

export default LibraryPage;