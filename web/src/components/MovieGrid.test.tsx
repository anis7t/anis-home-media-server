import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { describe, expect, it } from 'vitest';

import { MovieGrid } from './MovieGrid';
import type { MovieSummary } from '../lib/api/types';

function movie(title: string): MovieSummary {
  return { filename: `${title}.mkv`, title, poster: 'tmdb:1', position: 0, duration: 0, percent: 0 };
}

function posters() {
  return screen.getAllByRole('img', { hidden: true }).filter((el) => el.tagName === 'IMG');
}

describe('MovieGrid loading priority', () => {
  it('elevates only the first poster and lazy-loads the rest', () => {
    /*
     * Image-priority guidance: `fetchPriority="high"` is capped at one or two
     * images. Marking a whole visible row high priority makes them contend with
     * each other and dilutes the boost on the real LCP candidate.
     */
    render(
      <MemoryRouter>
        <MovieGrid movies={[movie('A'), movie('B'), movie('C')]} />
      </MemoryRouter>,
    );

    const images = posters();
    expect(images).toHaveLength(3);

    expect(images[0]).toHaveAttribute('fetchpriority', 'high');
    expect(images[0]).not.toHaveAttribute('loading', 'lazy');

    // Below-the-fold posters get `loading="lazy"` ALONE - never fetchpriority=low.
    for (const image of images.slice(1)) {
      expect(image).toHaveAttribute('loading', 'lazy');
      expect(image).not.toHaveAttribute('fetchpriority');
    }
  });

  it('reserves poster space with explicit dimensions to prevent layout shift', () => {
    render(
      <MemoryRouter>
        <MovieGrid movies={[movie('A')]} />
      </MemoryRouter>,
    );
    const image = posters()[0];
    expect(image).toHaveAttribute('width', '200');
    expect(image).toHaveAttribute('height', '300');
  });

  it('renders an honest placeholder when a title has no artwork', () => {
    render(
      <MemoryRouter>
        <MovieGrid movies={[{ ...movie('A'), poster: null }]} />
      </MemoryRouter>,
    );
    // The accessible name stays "Poster for A" whether or not artwork loaded -
    // only the glyph differs.
    expect(screen.getByRole('img', { name: /poster for A/i })).toBeInTheDocument();
  });

  it('shows a progress bar only for partially watched titles', () => {
    const { rerender } = render(
      <MemoryRouter>
        <MovieGrid movies={[{ ...movie('A'), percent: 50 }]} />
      </MemoryRouter>,
    );
    expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '50');

    rerender(
      <MemoryRouter>
        <MovieGrid movies={[movie('A')]} />
      </MemoryRouter>,
    );
    expect(screen.queryByRole('progressbar')).not.toBeInTheDocument();
  });
});