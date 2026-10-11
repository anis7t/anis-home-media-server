import { Link } from 'react-router';
import type { MovieSummary } from '../lib/api/spec-drift';
import { posterUrl } from '../lib/api/poster';
import { PosterImage, type PosterPriority } from './PosterImage';

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

  return (
    <Link
      to={href}
      className="card-ring group block overflow-hidden rounded-xl bg-obsidian-800 ring-1 ring-white/5 transition hover:ring-brand-500/60 focus-visible:ring-2"
      data-testid="movie-card"
      data-filename={movie.filename}
    >
      <div className="relative aspect-2/3 w-full overflow-hidden">
        <PosterImage src={poster} alt={`Poster for ${movie.title}`} priority={priority} />

        {hasProgress ? (
          <div
            className="absolute inset-x-0 bottom-0 h-1 bg-black/60"
            role="progressbar"
            aria-valuenow={percent}
            aria-valuemin={0}
            aria-valuemax={100}
            aria-label={`${percent}% watched`}
          >
            <div className="brand-gradient h-full" style={{ width: `${percent}%` }} />
          </div>
        ) : null}
      </div>

      <div className="p-3">
        <h3 className="truncate text-sm font-semibold text-white group-hover:text-brand-400">
          {movie.title}
        </h3>
        <p className="mt-0.5 flex items-center gap-2 text-xs text-white/50">
          {movie.year ? <span>{movie.year}</span> : null}
          {movie.needs_transcode && !movie.is_transcoding ? (
            <span className="rounded bg-white/10 px-1.5 py-0.5 text-[10px] uppercase tracking-wide">
              HLS
            </span>
          ) : null}
          {movie.is_transcoding ? (
            <span className="rounded bg-brand-500/20 px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-brand-400">
              {Math.round(movie.transcode_progress ?? 0)}%
            </span>
          ) : null}
        </p>
      </div>
    </Link>
  );
}