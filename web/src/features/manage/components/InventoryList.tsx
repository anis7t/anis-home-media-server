import { NavLink } from 'react-router';
import { Icon } from '../../../components/icons';
import { formatBytes, type MovieItem } from '../../../lib/api/manage';
import { posterUrl } from '../../../lib/api/poster';

interface InventoryListProps {
  readonly movies: readonly MovieItem[];
  readonly loading: boolean;
  readonly auditLoading: boolean;
  readonly activeHlsMap: Map<string, { size_bytes: number }>;
  readonly searchQuery: string;
  readonly busy: boolean;
  readonly deleting: boolean;
  readonly onResetFilters: () => void;
  readonly onArchiveMovie: (movie: MovieItem) => void;
  readonly onDeleteClick: (movie: MovieItem) => void;
}

export function InventoryList({
  movies,
  loading,
  auditLoading,
  activeHlsMap,
  searchQuery,
  busy,
  deleting,
  onResetFilters,
  onArchiveMovie,
  onDeleteClick,
}: InventoryListProps) {
  if (loading) {
    return (
      <div className="py-12 flex flex-col items-center justify-center space-y-3">
        <div className="h-7 w-7 rounded-full border-2 border-white/10 border-t-brand-500 animate-spin" />
        <p className="text-xs text-white/50">Loading library media inventory…</p>
      </div>
    );
  }

  if (movies.length === 0) {
    return (
      <div className="rounded-2xl border border-white/10 bg-obsidian-900/40 p-8 text-center space-y-2">
        <p className="text-sm font-semibold text-white/70">No matching media files found</p>
        <p className="text-xs text-white/40">
          {searchQuery
            ? `No files matching "${searchQuery}".`
            : 'No media files in configured storage roots.'}
        </p>
        {searchQuery ? (
          <button
            type="button"
            onClick={onResetFilters}
            className="mt-2 rounded-full border border-white/15 bg-white/5 px-4 py-1.5 text-xs text-white/80 hover:bg-white/10 transition cursor-pointer"
          >
            Reset Filters
          </button>
        ) : null}
      </div>
    );
  }

  return (
    <div className="space-y-3">
      {movies.map((m) => {
        const ext = m.filename.split('.').pop()?.toUpperCase() ?? 'VIDEO';
        const isMkv = m.filename.toLowerCase().endsWith('.mkv') || m.needs_transcode === true;
        const hlsItem =
          activeHlsMap.get(m.filename.toLowerCase()) ||
          activeHlsMap.get((m.filename.split(/[\/\\]/).pop() ?? '').toLowerCase());
        const hasHlsCache = m.hls_cached === true || Boolean(hlsItem);
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
                  {m.year ? <span className="text-xs text-white/50">({m.year})</span> : null}

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
                    auditLoading && m.hls_cached === undefined ? (
                      <span className="rounded-md bg-amber-500/10 border border-amber-500/20 px-1.5 py-0.5 text-[10px] font-medium text-amber-300/70 flex items-center gap-1 animate-pulse">
                        <span className="h-1.5 w-1.5 rounded-full bg-amber-400/50 animate-ping" />
                        Checking cache…
                      </span>
                    ) : (
                      <span className="rounded-md bg-amber-500/15 border border-amber-500/30 px-1.5 py-0.5 text-[10px] font-semibold text-amber-300">
                        ⚙ On-Demand HLS
                      </span>
                    )
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

                <p
                  className="font-mono text-[11px] text-white/40 truncate select-all"
                  title={m.filename}
                >
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
                  onClick={() => onArchiveMovie(m)}
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
                onClick={() => onDeleteClick(m)}
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
  );
}
