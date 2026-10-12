/**
 * Documented divergence between `docs/openapi.yaml` and the live API.
 *
 * Found 2026-10-12 while building the Phase 2 library slice, by calling
 * `GET /api/movies` on the running service and comparing it with the generated
 * types. This file exists so the gap is greppable and reviewable instead of
 * being papered over with casts scattered through the components.
 *
 * ## The gap
 *
 * `MovieSummaryItem` in the spec declares `poster_path?: string | null`. **The
 * real response has no `poster_path` field at all.** It returns `poster`, in a
 * tagged-string form, plus several fields the spec omits entirely:
 *
 * ```
 * spec   : poster_path?: string | null      -> /tmdb-poster/<id> | /poster/<path>
 * reality: poster: "tmdb:62" | "local:<rel>" -> see poster.ts
 * ```
 *
 * Building the poster URL from the spec's field name yields a grid of empty
 * images for the entire library. The server's own resolution rule is
 * `app/services/media_service.py:678-694` (and `poster_for` at `:242`), which
 * branches on the `tmdb:` prefix and strips the 6-character `local:` prefix.
 *
 * ## What is NOT done here
 *
 * `schema.ts` is generated and is left untouched. Correcting `docs/openapi.yaml`
 * is Phase 1 contract work and must not be done silently from inside Phase 2 -
 * `tests/test_api_contracts.py` asserts against it. The correction is reported,
 * not applied.
 *
 * Everything below is additive and source-local.
 */
import type { MovieDetailsResponse, MovieListResponse, MovieSummaryItem } from './types';

/** Fields the live `/api/movies` returns that the spec does not declare. */
export interface MovieSummaryDrift {
  /** Tagged poster reference: `tmdb:<id>`, `local:<relpath>`, or absent. */
  poster?: string | null;
  /** Raw JSON **string** (not a parsed object) holding tagline/cast/crew. */
  details_json?: string | null;
  /** Unix seconds of the last TMDb metadata refresh. */
  last_metadata_refresh?: number | null;
}

/** Spec-declared shape plus the fields reality actually sends. */
export type MovieSummary = MovieSummaryItem & MovieSummaryDrift;

/** The same widening, applied to the endpoints that embed a movie summary. */
export type MovieListResponseLive = Omit<MovieListResponse, 'movies' | 'watching'> & {
  movies: MovieSummary[];
  watching: MovieSummary[];
};

export type MovieDetailsResponseLive = Omit<MovieDetailsResponse, 'movie' | 'specs'> & {
  movie: MovieSummary;
  specs: TechnicalSpecsDrift;
};

/**
 * Fields the live `/api/movie/<file>` sends in `specs` that the spec omits.
 *
 * `extract_media_technical_specs()` (`app/services/media_service.py:333`) builds
 * ten keys. The generated `TechnicalSpecs` declares seven, and two of those use
 * different names than the server sends:
 *
 * ```
 * spec   : filesize        -> reality: file_size
 * spec   : (absent)        -> reality: container, resolution_badge,
 *                                     video_profile, subtitles[]
 * ```
 *
 * The legacy Jinja page renders all of them, so this is a contract gap rather
 * than a new capability. Correcting `docs/openapi.yaml` is Phase 1 contract work
 * and is reported here, not applied silently - `tests/test_api_contracts.py`
 * asserts against the spec.
 */
export interface TechnicalSpecsDrift {
  resolution?: string | null;
  resolution_badge?: string | null;
  video_codec?: string | null;
  video_profile?: string | null;
  audio_codec?: string | null;
  audio_channels?: string | null;
  container?: string | null;
  /** Display string such as `"2.4 GB"`. Spec calls this `filesize`. */
  file_size?: string | null;
  bitrate?: string | null;
  aspect_ratio?: string | null;
  /** Sidecar subtitle track descriptions; empty when none are available. */
  subtitles?: string[] | null;
}