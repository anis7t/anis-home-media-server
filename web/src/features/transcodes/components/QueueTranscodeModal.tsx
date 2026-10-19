import { useState, useMemo } from 'react';
import { createPortal } from 'react-dom';
import { Icon } from '../../../components/icons';
import type { MovieItem } from '../../../lib/api/manage';

interface QueueTranscodeModalProps {
  readonly isOpen: boolean;
  readonly movies: readonly MovieItem[];
  readonly onClose: () => void;
  readonly onSubmit: (filename: string, preset: string, priority: number) => Promise<void>;
  readonly busy: boolean;
}

const PRESET_OPTIONS = [
  {
    id: 'hls:1080p',
    name: '1080p Full HD (Recommended)',
    desc: 'Target ~5.0 Mbps • ISO BMFF fMP4 • Dual AMF Hardware Acceleration',
    badge: '1080p',
  },
  {
    id: 'hls:720p',
    name: '720p Standard HD',
    desc: 'Target ~2.7 Mbps • Efficient Mobile & Remote Streaming',
    badge: '720p',
  },
  {
    id: 'hls:4k',
    name: '4K 2160p Ultra HD',
    desc: 'Target ~14.2 Mbps • Cinema Grade for 4K Displays',
    badge: '4K',
  },
  {
    id: 'hls:480p',
    name: '480p Compact',
    desc: 'Target ~1.4 Mbps • Low-Bandwidth Data Saver',
    badge: '480p',
  },
];

export function QueueTranscodeModal({
  isOpen,
  movies,
  onClose,
  onSubmit,
  busy,
}: QueueTranscodeModalProps) {
  const [search, setSearch] = useState('');
  const [selectedFilename, setSelectedFilename] = useState<string>('');
  const [selectedPreset, setSelectedPreset] = useState<string>('hls:1080p');
  const [priority, setPriority] = useState<number>(10);
  const [error, setError] = useState<string | null>(null);

  const filteredMovies = useMemo(() => {
    if (!search.trim()) return movies.slice(0, 30);
    const q = search.toLowerCase().trim();
    return movies.filter(
      (m) =>
        m.title.toLowerCase().includes(q) ||
        m.filename.toLowerCase().includes(q) ||
        (m.year && String(m.year).includes(q))
    ).slice(0, 40);
  }, [movies, search]);

  if (!isOpen || typeof document === 'undefined') return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedFilename) {
      setError('Please select a movie to transcode.');
      return;
    }
    setError(null);
    try {
      await onSubmit(selectedFilename, selectedPreset, priority);
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  };

  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="queue-modal-title"
      className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-md overflow-y-auto animate-fade-in"
      onClick={onClose}
    >
      <div
        className="glass-card max-w-xl w-full my-auto rounded-3xl p-6 sm:p-8 space-y-6 shadow-2xl border border-white/15 animate-scale-in"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between border-b border-white/10 pb-4">
          <div className="flex items-center gap-2.5">
            <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-brand-500/15 border border-brand-500/30 text-brand-400">
              <Icon name="bolt" size={18} />
            </div>
            <div>
              <h3 id="queue-modal-title" className="text-base sm:text-lg font-bold text-white">
                Queue Transcode Job
              </h3>
              <p className="text-xs text-white/50">
                Trigger dual-GPU fMP4 encoding with custom quality presets
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="flex h-8 w-8 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/70 hover:bg-white/10 hover:text-white transition cursor-pointer"
            aria-label="Close dialog"
          >
            ✕
          </button>
        </div>

        {error ? (
          <div className="rounded-xl border border-rose-500/30 bg-rose-500/10 p-3 text-xs text-rose-300">
            {error}
          </div>
        ) : null}

        <form onSubmit={handleSubmit} className="space-y-5">
          {/* Movie Search & Selector */}
          <div className="space-y-2">
            <label className="block text-xs font-semibold text-white/80">
              Select Movie Title
            </label>
            <div className="relative">
              <input
                type="text"
                placeholder="Filter library titles..."
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                className="w-full rounded-xl border border-white/10 bg-obsidian-850 py-2 pl-3 pr-8 text-xs text-white placeholder-white/40 focus:border-brand-500/60 focus:outline-none"
              />
              {search ? (
                <button
                  type="button"
                  onClick={() => setSearch('')}
                  className="absolute right-2.5 top-1/2 -translate-y-1/2 text-white/40 hover:text-white text-xs"
                >
                  ✕
                </button>
              ) : null}
            </div>

            <div className="max-h-40 overflow-y-auto space-y-1 rounded-xl border border-white/10 bg-obsidian-900/60 p-1.5 scrollbar-thin">
              {filteredMovies.length === 0 ? (
                <p className="p-3 text-center text-xs text-white/40">No matching movies found</p>
              ) : (
                filteredMovies.map((m) => {
                  const isSelected = selectedFilename === m.filename;
                  return (
                    <button
                      key={m.filename}
                      type="button"
                      onClick={() => setSelectedFilename(m.filename)}
                      className={`w-full flex items-center justify-between text-left px-3 py-2 rounded-lg text-xs transition cursor-pointer ${
                        isSelected
                          ? 'bg-brand-500/25 border border-brand-500/40 text-white font-semibold'
                          : 'text-white/70 hover:bg-white/5 hover:text-white'
                      }`}
                    >
                      <span className="truncate pr-2">
                        {m.title} {m.year ? `(${m.year})` : ''}
                      </span>
                      {m.hls_cached ? (
                        <span className="text-[10px] text-emerald-400 bg-emerald-500/15 border border-emerald-500/30 px-1.5 py-0.5 rounded">
                          Cached
                        </span>
                      ) : null}
                    </button>
                  );
                })
              )}
            </div>
          </div>

          {/* Preset Selector */}
          <div className="space-y-2">
            <label className="block text-xs font-semibold text-white/80">
              Quality Preset
            </label>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
              {PRESET_OPTIONS.map((opt) => {
                const isSelected = selectedPreset === opt.id;
                return (
                  <button
                    key={opt.id}
                    type="button"
                    onClick={() => setSelectedPreset(opt.id)}
                    className={`p-3 rounded-2xl border text-left transition cursor-pointer ${
                      isSelected
                        ? 'border-brand-500 bg-brand-500/15 shadow-md shadow-brand-500/10'
                        : 'border-white/10 bg-obsidian-850 hover:bg-white/5'
                    }`}
                  >
                    <div className="flex items-center justify-between">
                      <span className="text-xs font-bold text-white">{opt.badge}</span>
                      <span
                        className={`text-[10px] font-semibold px-2 py-0.5 rounded-full ${
                          isSelected
                            ? 'bg-brand-500 text-white'
                            : 'bg-white/10 text-white/60'
                        }`}
                      >
                        {isSelected ? 'Selected' : 'Choose'}
                      </span>
                    </div>
                    <p className="text-[11px] text-white/60 mt-1 leading-snug">{opt.desc}</p>
                  </button>
                );
              })}
            </div>
          </div>

          {/* Priority Toggle */}
          <div className="flex items-center justify-between rounded-2xl border border-white/10 bg-obsidian-850 p-3">
            <div>
              <h5 className="text-xs font-bold text-white">Execution Priority</h5>
              <p className="text-[11px] text-white/50">
                {priority >= 10 ? 'High Priority (Processes ahead of sweeps)' : 'Background (Deferred)'}
              </p>
            </div>
            <div className="flex items-center gap-1.5">
              <button
                type="button"
                onClick={() => setPriority(0)}
                className={`px-3 py-1 rounded-full text-xs font-medium transition cursor-pointer ${
                  priority === 0
                    ? 'bg-white/20 text-white'
                    : 'text-white/40 hover:text-white'
                }`}
              >
                Normal (0)
              </button>
              <button
                type="button"
                onClick={() => setPriority(10)}
                className={`px-3 py-1 rounded-full text-xs font-bold transition cursor-pointer ${
                  priority === 10
                    ? 'bg-brand-500 text-white shadow-sm'
                    : 'text-white/40 hover:text-white'
                }`}
              >
                High (10)
              </button>
            </div>
          </div>

          {/* Form Actions */}
          <div className="flex items-center justify-end gap-3 pt-2">
            <button
              type="button"
              onClick={onClose}
              disabled={busy}
              className="px-5 py-2.5 rounded-full border border-white/15 bg-white/5 text-xs font-semibold text-white/70 hover:bg-white/10 hover:text-white transition cursor-pointer"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={busy || !selectedFilename}
              className="brand-gradient px-6 py-2.5 rounded-full text-xs font-bold text-white shadow-lg shadow-brand-500/25 hover:scale-105 active:scale-95 transition disabled:opacity-50 disabled:pointer-events-none cursor-pointer flex items-center gap-2"
            >
              <Icon name="bolt" size={14} />
              <span>{busy ? 'Admitting...' : 'Start Transcode'}</span>
            </button>
          </div>
        </form>
      </div>
    </div>,
    document.body
  );
}
