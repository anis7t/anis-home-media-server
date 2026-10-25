import type { MovieSummary } from '../lib/api/types';
import { MovieCard } from './MovieCard';

interface MovieGridProps {
  readonly movies: readonly MovieSummary[];
  /** Heading shown above the grid; omit for a bare grid. */
  readonly title?: string;
}

/**
 * Only the very first card is treated as the LCP candidate. The image-priority
 * guidance caps `fetchPriority="high"` at one or two images - marking a whole
 * visible row as high priority causes them to contend with each other and
 * dilutes the boost.
 */
export function MovieGrid({ movies, title }: MovieGridProps) {
  return (
    <section aria-labelledby={title ? 'grid-heading' : undefined}>
      {title ? (
        <h2 id="grid-heading" className="mb-4 text-lg font-semibold text-white">
          {title}
        </h2>
      ) : null}

      <ul className="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 xl:grid-cols-7">
        {movies.map((movie, index) => (
          <li key={movie.filename}>
            <MovieCard movie={movie} priority={index === 0 ? 'lcp' : 'lazy'} />
          </li>
        ))}
      </ul>
    </section>
  );
}