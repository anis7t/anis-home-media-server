/**
 * Resolution of prior divergence between `docs/openapi.yaml` and the live API.
 *
 * Originally documented 2026-10-12 during Phase 2.
 * Fully resolved in Architectural Tightening Slice 4 (2026-10-25): `docs/openapi.yaml`
 * now canonically defines `poster`, `details_json`, `last_metadata_refresh`,
 * `resolution_badge`, `video_profile`, `container`, `file_size`, and `subtitles`.
 *
 * This file remains as a backward-compatible adapter export aliasing the
 * canonical generated types from `types.ts`. All active code should import
 * directly from `types.ts` or `schema.ts`.
 */
import type { MovieDetailsResponse, MovieListResponse, MovieSummaryItem, TechnicalSpecs } from './types';

/**
 * @deprecated Legacy drift representation. Canonical schema is now `components['schemas']['MovieSummaryItem']` in `docs/openapi.yaml`.
 */
export interface MovieSummaryDrift {
  /** Tagged poster reference: `tmdb:<id>`, `local:<relpath>`, or absent. */
  poster?: string | null;
  /** Raw JSON **string** (not a parsed object) holding tagline/cast/crew. */
  details_json?: string | null;
  /** Unix seconds of the last TMDb metadata refresh. */
  last_metadata_refresh?: number | null;
}

/**
 * @deprecated Use `MovieSummaryItem` from `web/src/lib/api/types.ts` or `web/src/lib/api/schema.ts`.
 * Canonical schema: `docs/openapi.yaml` #/components/schemas/MovieSummaryItem.
 */
export type MovieSummary = MovieSummaryItem;

/**
 * @deprecated Use `MovieListResponse` from `web/src/lib/api/types.ts`.
 * Canonical schema: `docs/openapi.yaml` #/components/schemas/MovieListResponse.
 */
export type MovieListResponseLive = MovieListResponse;

/**
 * @deprecated Use `MovieDetailsResponse` from `web/src/lib/api/types.ts`.
 * Canonical schema: `docs/openapi.yaml` #/components/schemas/MovieDetailsResponse.
 */
export type MovieDetailsResponseLive = MovieDetailsResponse;

/**
 * @deprecated Use `TechnicalSpecs` from `web/src/lib/api/types.ts`.
 * Canonical schema: `docs/openapi.yaml` #/components/schemas/TechnicalSpecs.
 */
export type TechnicalSpecsDrift = TechnicalSpecs;