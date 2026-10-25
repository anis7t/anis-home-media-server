import { Link } from 'react-router';
import type { MovieSummary } from '../../lib/api/types';
import { backdropUrl, posterUrl } from '../../lib/api/poster';
import { Icon } from '../../components/icons';

interface HeroSpotlightProps {
  readonly movie: MovieSummary;
  readonly hasTopBanner?: boolean;
}

function formatRuntime(minutes: number | null | undefined): string | null {
  if (!minutes || minutes <= 0) return null;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

export function HeroSpotlight({ movie, hasTopBanner = false }: HeroSpotlightProps) {
  const watchHref = `/watch/${movie.filename.split('/').map(encodeURIComponent).join('/')}`;
  const detailsHref = `/movie/${movie.filename.split('/').map(encodeURIComponent).join('/')}`;

  const backdrop = movie.tmdb_id ? backdropUrl(movie.tmdb_id) : null;
  const poster = posterUrl(movie.poster);
  const imageSrc = backdrop || poster;

  const rating = typeof movie.rating === 'number' && movie.rating > 0 ? movie.rating.toFixed(1) : null;
  const runtime = formatRuntime(movie.runtime);
  const isContinue = (movie.percent ?? 0) > 0;

  return (
    <section
      aria-label="Featured spotlight"
      data-testid="hero-spotlight"
      className={`relative -mx-4 sm:-mx-6 mb-8 overflow-hidden bg-obsidian-900 shadow-2xl ${
        hasTopBanner
          ? 'mt-4 sm:mt-6 rounded-3xl border border-white/10'
          : '-mt-6 sm:-mt-8 rounded-b-3xl border-b border-white/10'
      }`}
    >
      {/* Cinematic Full-Bleed Artwork */}
      <div className="relative min-h-[360px] sm:min-h-[440px] md:min-h-[500px] w-full overflow-hidden">
        {imageSrc ? (
          <img
            src={imageSrc}
            alt=""
            aria-hidden="true"
            className="absolute inset-0 h-full w-full object-cover object-top opacity-40 filter transition-transform duration-700 ease-out hover:scale-105"
          />
        ) : (
          <div className="absolute inset-0 bg-gradient-to-br from-brand-950/40 via-obsidian-900 to-obsidian-950" />
        )}

        {/* Ambient Dark Gradients & Vignette */}
        <div className="absolute inset-0 bg-gradient-to-t from-obsidian-950 via-obsidian-950/70 to-transparent" />
        <div className="absolute inset-0 bg-gradient-to-r from-obsidian-950 via-obsidian-950/80 to-transparent sm:max-w-3xl" />
        <div className="absolute inset-0 bg-[radial-gradient(circle_at_top_right,rgba(229,9,20,0.12),transparent_50%)]" />

        {/* Content Container */}
        <div className="relative flex flex-col justify-end min-h-[360px] sm:min-h-[440px] md:min-h-[500px] px-6 pb-10 pt-16 sm:px-10 sm:pb-12 max-w-3xl">
          {/* Top Pill */}
          <div className="mb-3 flex items-center gap-2">
            <span className="inline-flex items-center gap-1.5 rounded-full bg-brand-500/20 px-3 py-1 text-xs font-semibold uppercase tracking-wider text-brand-300 border border-brand-500/30 backdrop-blur-md">
              <Icon name="sparkle" size={12} className="text-brand-400" />
              {isContinue ? 'Continue Watching' : 'Featured Spotlight'}
            </span>
            {movie.needs_transcode ? (
              <span className="rounded-full bg-white/10 px-2.5 py-0.5 text-[11px] font-medium tracking-wide text-white/70">
                ADAPTIVE STREAM
              </span>
            ) : (
              <span className="rounded-full bg-emerald-500/15 px-2.5 py-0.5 text-[11px] font-medium tracking-wide text-emerald-300 border border-emerald-500/30">
                Direct Play
              </span>
            )}
          </div>

          {/* Title */}
          <h1 className="text-3xl font-extrabold tracking-tight text-white sm:text-4xl md:text-5xl drop-shadow-md">
            {movie.title}{movie.year ? <span className="ml-2 font-normal text-white/60">({movie.year})</span> : null}
          </h1>

          {/* Metadata Badges */}
          <div className="mt-3 flex flex-wrap items-center gap-3 text-xs sm:text-sm text-white/70">
            {rating ? (
              <span className="flex items-center gap-1 font-semibold text-amber-300 bg-amber-400/10 px-2 py-0.5 rounded-md border border-amber-400/20">
                <Icon name="star" size={13} className="text-amber-400" />
                {rating}
              </span>
            ) : null}
            {movie.year ? <span>{movie.year}</span> : null}
            {runtime ? (
              <>
                <span className="text-white/30">•</span>
                <span>{runtime}</span>
              </>
            ) : null}
            {movie.genres ? (
              <>
                <span className="text-white/30">•</span>
                <span className="text-white/60">{movie.genres}</span>
              </>
            ) : null}
          </div>

          {/* Overview text */}
          {movie.overview ? (
            <p className="mt-3.5 line-clamp-2 sm:line-clamp-3 text-sm leading-relaxed text-white/70">
              {movie.overview}
            </p>
          ) : null}

          {/* Action Buttons */}
          <div className="mt-6 flex flex-wrap items-center gap-3 sm:gap-4">
            <Link
              to={watchHref}
              className="brand-gradient brand-glow group flex items-center gap-2.5 rounded-full px-6 py-3 text-sm font-bold text-white shadow-lg transition-all duration-200 hover:scale-105 active:scale-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white"
            >
              <Icon name="play" size={16} className="text-white" />
              <span>{isContinue ? 'Resume Playback' : 'Watch Now'}</span>
            </Link>

            <Link
              to={detailsHref}
              className="glass-pill flex items-center gap-2 rounded-full px-5 py-3 text-sm font-semibold text-white/90 shadow-sm transition-all duration-200 hover:bg-white/15 hover:text-white active:scale-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/40"
            >
              <Icon name="info" size={15} className="text-white/70" />
              <span>Details & Specs</span>
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}
