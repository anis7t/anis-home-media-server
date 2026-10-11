import { Link, useParams } from 'react-router';
import { getMovieDetails } from '../../lib/api/client';
import { posterUrl, backdropUrl } from '../../lib/api/poster';
import { useDeviceId } from '../../lib/useDeviceId';
import { StateMessage } from '../../components/StateMessage';
import { useAsync } from '../../lib/useAsync';
import { PosterImage } from '../../components/PosterImage';

/**
 * `details_json` arrives as a raw JSON *string*, not an object, and the spec
 * types it as an empty record. Parse defensively and treat a malformed value as
 * absent rather than letting it take down the screen.
 */
interface ExtendedDetails {
  tagline?: string;
  certification?: string;
  directors?: string[];
  cast?: { name: string; character?: string }[];
}

function parseDetails(raw: unknown): ExtendedDetails {
  if (typeof raw !== 'string' || raw.length === 0) return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    if (parsed && typeof parsed === 'object') return parsed as ExtendedDetails;
  } catch {
    // Malformed JSON from the server: degrade to no extended data.
  }
  return {};
}

export function MovieDetailsPage() {
  // Splat route: the filename is a relative path and contains slashes.
  const params = useParams();
  const filename = params['*'] ?? '';
  const deviceId = useDeviceId();

  const { data, error, loading } = useAsync(
    (signal) => getMovieDetails(decodeURIComponent(filename), { signal, deviceId }),
    [filename, deviceId],
  );

  return (
    <StateMessage
      loading={loading}
      error={error}
      empty={false}
      emptyText=""
    >
      {data ? (
        <article data-testid="movie-details">
          <div className="relative mb-8 h-56 overflow-hidden rounded-2xl sm:h-72">
            {backdropUrl(data.movie.tmdb_id) ? (
              <img
                src={backdropUrl(data.movie.tmdb_id) ?? ''}
                alt=""
                // The backdrop is the largest above-the-fold image on this
                // screen, so it is the LCP candidate here.
                fetchPriority="high"
                className="h-full w-full object-cover"
              />
            ) : null}
            <div className="absolute inset-0 bg-gradient-to-t from-obsidian-950 via-obsidian-950/60 to-transparent" />
          </div>

          <div className="-mt-24 flex flex-col gap-6 px-2 sm:flex-row">
            <div className="w-32 shrink-0 overflow-hidden rounded-xl ring-1 ring-white/10 sm:w-44">
              <div className="aspect-2/3">
                <PosterImage
                  src={posterUrl(data.movie.poster)}
                  alt={`Poster for ${data.movie.title}`}
                  priority="lazy"
                />
              </div>
            </div>

            <div className="flex-1 space-y-4">
              <header>
                <h1 className="text-3xl font-bold text-white">{data.movie.title}</h1>
                <p className="mt-1 text-sm text-white/50">
                  {[data.movie.year, data.specs.resolution, data.formatted_runtime]
                    .filter(Boolean)
                    .join(' · ')}
                </p>
              </header>

              {parseDetails(data.extended).tagline ? (
                <p className="text-sm italic text-white/60">
                  {parseDetails(data.extended).tagline}
                </p>
              ) : null}

              {data.movie.overview ? (
                <p className="max-w-3xl text-sm leading-relaxed text-white/75">
                  {data.movie.overview}
                </p>
              ) : null}

              <dl className="flex flex-wrap gap-x-6 gap-y-2 text-xs text-white/50">
                {data.specs.video_codec ? (
                  <div>
                    <dt className="inline text-white/35">Video </dt>
                    <dd className="inline">{data.specs.video_codec}</dd>
                  </div>
                ) : null}
                {data.specs.audio_codec ? (
                  <div>
                    <dt className="inline text-white/35">Audio </dt>
                    <dd className="inline">{data.specs.audio_codec}</dd>
                  </div>
                ) : null}
                {data.movie.rating ? (
                  <div>
                    <dt className="inline text-white/35">Rating </dt>
                    <dd className="inline">{data.movie.rating.toFixed(1)}</dd>
                  </div>
                ) : null}
              </dl>

              <Link
                to={`/watch/${data.movie.filename
                  .split('/')
                  .map(encodeURIComponent)
                  .join('/')}`}
                data-testid="play-button"
                className="card-ring inline-block rounded-lg brand-gradient px-6 py-2.5 text-sm font-semibold text-white"
              >
                ▶ Play
              </Link>
            </div>
          </div>
        </article>
      ) : null}
    </StateMessage>
  );
}

export default MovieDetailsPage;