import { Link } from 'react-router';
import type { MovieSummary } from '../lib/api/types';
import { posterUrl } from '../lib/api/poster';
import { PosterImage, type PosterPriority } from './PosterImage';
import { Icon } from './icons';

interface MovieCardProps {
  readonly movie: MovieSummary;
  /** Only the first few above-the-fold cards are LCP candidates. */
  readonly priority?: PosterPriority;
}

function progressPercent(movie: MovieSummary): number {
  const percent = movie.percent ?? 0;
  return Math.max(0, Math.min(100, Math.round(percent)));
}

export function MovieCard({ movie, priority = 'lazy' }: MovieCardProps) {
  const href = `/movie/${movie.filename.split('/').map(encodeURIComponent).join('/')}`;
  const poster = posterUrl(movie.poster);
  const percent = progressPercent(movie);
  const hasProgress = percent > 0;
  const rating = typeof movie.rating === 'number' && movie.rating > 0 ? movie.rating.toFixed(1) : null;

  return (
    <Link
      to={href}
      className="card-ring group block overflow-hidden rounded-2xl bg-obsidian-850 ring-1 ring-white/10 transition-all duration-300 hover:-translate-y-1.5 hover:ring-brand-500/50 hover:shadow-2xl hover:shadow-black/70 focus-visible:ring-2"
      data-testid="movie-card"
      data-filename={movie.filename}
    >
      <div className="relative aspect-2/3 w-full overflow-hidden bg-obsidian-900">
        <div className="h-full w-full transition-transform duration-500 ease-out group-hover:scale-105">
          <PosterImage src={poster} alt={`Poster for ${movie.title}`} priority={priority} />
        </div>

        {/* Floating Rating Badge */}
        {rating ? (
          <div className="absolute right-2 top-2 flex items-center gap-1 rounded-md bg-black/75 px-1.5 py-0.5 text-[11px] font-semibold text-amber-300 shadow-sm backdrop-blur-md">
            <Icon name="star" size={11} className="text-amber-400" />
            <span>{rating}</span>
          </div>
        ) : null}

        {/* Hover Center Play Button Overlay */}
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center bg-black/25 opacity-0 backdrop-blur-[1px] transition-all duration-300 group-hover:opacity-100">
          <div className="brand-gradient brand-glow-sm flex h-11 w-11 scale-90 items-center justify-center rounded-full text-white shadow-lg transition-transform duration-300 group-hover:scale-100">
            <Icon name="play" size={16} className="ml-0.5 text-white" />
          </div>
        </div>

        {/* Progress Bar for partially watched titles */}
        {hasProgress ? (
          <div
            className="absolute inset-x-0 bottom-0 h-1.5 bg-black/70"
            role="progressbar"
            aria-valuenow={percent}
            aria-valuemin={0}
            aria-valuemax={100}
            aria-label={`${percent}% watched`}
          >
            <div className="brand-gradient h-full transition-[width] duration-300" style={{ width: `${percent}%` }} />
          </div>
        ) : null}
      </div>

      <div className="p-3.5">
        <h3 className="truncate text-sm font-semibold text-white transition-colors duration-200 group-hover:text-brand-400">
          {movie.title}
        </h3>
        <div className="mt-1 flex items-center justify-between text-xs text-white/50">
          <div className="flex items-center gap-2">
            {movie.year ? <span>{movie.year}</span> : null}
            {movie.needs_transcode && !movie.is_transcoding ? (
              <span className="rounded bg-white/10 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-white/70">
                ADAPTIVE
              </span>
            ) : null}
            {movie.is_transcoding ? (
              <span className="rounded bg-brand-500/20 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-brand-400">
                {Math.round(movie.transcode_progress ?? 0)}%
              </span>
            ) : null}
          </div>
        </div>
      </div>
    </Link>
  );
}