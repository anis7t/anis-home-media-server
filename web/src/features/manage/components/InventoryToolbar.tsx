import { Icon } from '../../../components/icons';

export type FilterCategory = 'all' | 'hls' | 'direct' | 'watched' | 'unwatched';
export type SortField = 'title' | 'year' | 'recent';

interface InventoryToolbarProps {
  readonly searchQuery: string;
  readonly onSearchChange: (query: string) => void;
  readonly activeFilter: FilterCategory;
  readonly onFilterChange: (filter: FilterCategory) => void;
  readonly sortBy: SortField;
  readonly onSortChange: (sort: SortField) => void;
  readonly totalCount: number;
}

export function InventoryToolbar({
  searchQuery,
  onSearchChange,
  activeFilter,
  onFilterChange,
  sortBy,
  onSortChange,
  totalCount,
}: InventoryToolbarProps) {
  const filterChips: Array<{ id: FilterCategory; label: string }> = [
    { id: 'all', label: `All (${totalCount})` },
    { id: 'hls', label: 'Adaptive / MKV' },
    { id: 'direct', label: 'Direct Play' },
    { id: 'watched', label: 'In Progress' },
    { id: 'unwatched', label: 'Unwatched' },
  ];

  return (
    <div className="flex flex-col sm:flex-row gap-3 items-stretch sm:items-center justify-between">
      {/* Search Box */}
      <div className="relative flex-1">
        <span className="absolute inset-y-0 left-3.5 flex items-center text-white/30 pointer-events-none">
          <Icon name="search" size={14} />
        </span>
        <input
          type="text"
          value={searchQuery}
          onChange={(e) => onSearchChange(e.target.value)}
          placeholder="Filter by title, filename, or year…"
          className="w-full rounded-2xl border border-white/15 bg-obsidian-900/80 py-2.5 pl-9 pr-8 text-xs text-white placeholder-white/40 focus:border-brand-500 focus:outline-none transition"
        />
        {searchQuery ? (
          <button
            type="button"
            onClick={() => onSearchChange('')}
            className="absolute inset-y-0 right-3 flex items-center text-white/40 hover:text-white cursor-pointer"
            title="Clear search"
          >
            ✕
          </button>
        ) : null}
      </div>

      {/* Category Chips */}
      <div className="flex items-center gap-1.5 overflow-x-auto pb-1 sm:pb-0 scrollbar-none">
        {filterChips.map((chip) => (
          <button
            key={chip.id}
            type="button"
            onClick={() => onFilterChange(chip.id)}
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
          onChange={(e) => onSortChange(e.target.value as SortField)}
          className="rounded-xl border border-white/15 bg-obsidian-900/90 px-2.5 py-1.5 text-xs text-white/80 focus:border-brand-500 focus:outline-none"
        >
          <option value="title">Title (A–Z)</option>
          <option value="year">Year (Newest)</option>
          <option value="recent">Recently Watched</option>
        </select>
      </div>
    </div>
  );
}
