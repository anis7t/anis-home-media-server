/**
 * Resolution of prior divergence between `docs/openapi.yaml` and the live API.
 *
 * Originally documented 2026-10-12 during Phase 2.
 * Fully resolved in Architectural Tightening Slice 4 (2026-10-25): `docs/openapi.yaml`
 * now canonically defines `poster`, `details_json`, `last_metadata_refresh`,
 * `resolution_badge`, `video_profile`, `container`, `file_size`, and `subtitles`.
 *
 * This file remains as a backward-compatible adapter export aliasing the
 * canonical generated types from `types.ts`.
 */
import type { MovieDetailsResponse, MovieListResponse, MovieSummaryItem, TechnicalSpecs } from './types';

/** Fields the live `/api/movies` returns (now declared canonically in OpenAPI spec). */
export interface MovieSummaryDrift {
  /** Tagged poster reference: `tmdb:<id>`, `local:<relpath>`, or absent. */
  poster?: string | null;
  /** Raw JSON **string** (not a parsed object) holding tagline/cast/crew. */
  details_json?: string | null;
  /** Unix seconds of the last TMDb metadata refresh. */
  last_metadata_refresh?: number | null;
}

/** Spec-declared shape (now unified with server reality). */
export type MovieSummary = MovieSummaryItem;

/** Endpoint response types embedding unified movie summaries. */
export type MovieListResponseLive = MovieListResponse;

export type MovieDetailsResponseLive = MovieDetailsResponse;

export type TechnicalSpecsDrift = TechnicalSpecs;
