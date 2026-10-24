import { describe, expect, it } from 'vitest';
import { posterUrl, backdropUrl } from './poster';

describe('posterUrl', () => {
  it('resolves a tmdb: reference through the TMDb cache route', () => {
    expect(posterUrl('tmdb:62')).toBe('/tmdb-poster/62');
  });

  it('strips the 6-character local: prefix for local posters', () => {
    expect(posterUrl('local:posters/2001.jpg')).toBe('/poster/posters/2001.jpg');
  });

  it('encodes each path segment but keeps the separators', () => {
    // A local poster in a subdirectory must keep its slash, or the server's
    // <path:filename> route cannot resolve it.
    expect(posterUrl('local:sub dir/a b.jpg')).toBe('/poster/sub%20dir/a%20b.jpg');
  });

  it('returns null for a non-numeric tmdb id rather than a broken image', () => {
    // `/tmdb-poster/<int:...>` would 404 on anything non-numeric.
    expect(posterUrl('tmdb:abc')).toBeNull();
  });

  it('returns null when there is no poster', () => {
    expect(posterUrl(null)).toBeNull();
    expect(posterUrl(undefined)).toBeNull();
    expect(posterUrl('')).toBeNull();
  });

  it('returns null for an empty local: reference', () => {
    expect(posterUrl('local:')).toBeNull();
  });

  it('returns null for an unrecognised scheme', () => {
    expect(posterUrl('http://example.com/x.jpg')).toBeNull();
  });
});

describe('backdropUrl', () => {
  it('resolves a numeric TMDb id', () => {
    expect(backdropUrl(62)).toBe('/tmdb-backdrop/62');
  });

  it('rejects a missing id', () => {
    expect(backdropUrl(null)).toBeNull();
    expect(backdropUrl(undefined)).toBeNull();
    expect(backdropUrl(Number.NaN)).toBeNull();
  });
});