/**
 * Poster URL derivation.
 *
 * Mirrors the server's own rule at `app/services/media_service.py:678-694`:
 * a `poster` value beginning `tmdb:` resolves through the TMDb cache route,
 * anything else is a `local:` reference whose 6-character prefix is stripped
 * and handed to the local poster route.
 *
 * Routes (app/routes/api.py):
 *   - `:410` -> `/tmdb-poster/<int:tmdb_id>`
 *   - `:395` -> `/poster/<path:filename>`
 *   - `:429` -> `/tmdb-backdrop/<int:tmdb_id>`
 *
 * See `spec-drift.ts` for why this is built from `poster` and not from the
 * spec's declared `poster_path`.
 */
import { encodePathSegments } from './client';

const LOCAL_PREFIX = 'local:';
const TMDB_PREFIX = 'tmdb:';

export function posterUrl(poster: string | null | undefined): string | null {
  if (!poster) return null;

  if (poster.startsWith(TMDB_PREFIX)) {
    const id = poster.slice(TMDB_PREFIX.length);
    // The route is `<int:tmdb_id>`; a non-numeric tail would 404, and a broken
    // image is worse than an honest placeholder.
    if (!/^\d+$/.test(id)) return null;
    return `/tmdb-poster/${id}`;
  }

  if (poster.startsWith(LOCAL_PREFIX)) {
    const relative = poster.slice(LOCAL_PREFIX.length);
    if (!relative) return null;
    return `/poster/${encodePathSegments(relative)}`;
  }

  return null;
}

export function backdropUrl(tmdbId: number | null | undefined): string | null {
  if (typeof tmdbId !== 'number' || !Number.isFinite(tmdbId)) return null;
  return `/tmdb-backdrop/${tmdbId}`;
}