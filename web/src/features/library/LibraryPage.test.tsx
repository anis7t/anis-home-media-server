import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { HeroSpotlight } from './HeroSpotlight';
import { LibraryPage } from './LibraryPage';
import { AuthProvider } from '../../auth/AuthProvider';
import type { MovieSummaryLive } from './test-fixtures';

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : 'Error',
    json: async () => body,
  } as Response;
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
  /*
   * `window.localStorage.clear()` is deliberately NOT called here: jsdom 29
   * exposes no working localStorage, which means `useDeviceId` always takes its
   * try/catch fallback path in these tests. That is the resilient path, and
   * leaving it unstubbed keeps it exercised rather than bypassed.
   */
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function renderLibrary() {
  return render(
    <MemoryRouter>
      <LibraryPage />
    </MemoryRouter>,
  );
}

describe('LibraryPage states', () => {
  it('shows a loading state before the catalog arrives', () => {
    fetchMock.mockImplementation(() => new Promise(() => {}));
    renderLibrary();
    expect(screen.getByRole('status')).toHaveTextContent(/loading library/i);
  });

  it('renders one card per movie from the live contract', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse({
        movies: [
          { filename: 'a.mkv', title: 'Alpha', year: 2001, poster: 'tmdb:1', position: 0, duration: 0, percent: 0 },
          { filename: 'b.mkv', title: 'Beta', year: 2002, poster: 'tmdb:2', position: 0, duration: 0, percent: 0 },
        ] as MovieSummaryLive[],
        watching: [],
        total: 2,
      }),
    );

    renderLibrary();

    expect(await screen.findByText('Alpha')).toBeInTheDocument();
    expect(screen.getByText('Beta')).toBeInTheDocument();
    expect(screen.getAllByTestId('movie-card')).toHaveLength(2);
  });

  it('surfaces a failure rather than an empty library', async () => {
    fetchMock.mockImplementation(async () => jsonResponse({}, 500));
    renderLibrary();
    expect(await screen.findByRole('alert')).toHaveTextContent(/could not reach the media server/i);
  });

  it('explains an empty catalog instead of showing a blank grid', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse({ movies: [], watching: [], total: 0 }),
    );
    renderLibrary();
    await waitFor(() => {
      expect(screen.getByRole('status')).toHaveTextContent(/no movies found/i);
    });
  });

  it('only renders the continue-watching rail when something is in progress', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse({
        movies: [{ filename: 'a.mkv', title: 'Alpha', position: 0, duration: 100, percent: 0 }],
        watching: [
          { filename: 'a.mkv', title: 'Alpha', position: 50, duration: 100, percent: 50 },
        ],
        total: 1,
      }),
    );

    renderLibrary();

    expect(await screen.findByText('Continue watching')).toBeInTheDocument();
    expect(screen.getByText('All movies')).toBeInTheDocument();
  });

  it('filters movies in real-time when searching by title', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse({
        movies: [
          { filename: 'inception.mkv', title: 'Inception', year: 2010, poster: 'tmdb:1', position: 0, duration: 0, percent: 0 },
          { filename: 'interstellar.mkv', title: 'Interstellar', year: 2014, poster: 'tmdb:2', position: 0, duration: 0, percent: 0 },
          { filename: 'gladiator.mkv', title: 'Gladiator', year: 2000, poster: 'tmdb:3', position: 0, duration: 0, percent: 0 },
        ] as MovieSummaryLive[],
        watching: [],
        total: 3,
      }),
    );

    renderLibrary();

    expect(await screen.findByText('Inception')).toBeInTheDocument();
    expect(screen.getByText('Interstellar')).toBeInTheDocument();
    expect(screen.getByText('Gladiator')).toBeInTheDocument();

    const searchInput = screen.getByRole('textbox', { name: /search movies/i });
    const { fireEvent } = await import('@testing-library/react');
    fireEvent.change(searchInput, { target: { value: 'Incep' } });

    expect(screen.getByText('Inception')).toBeInTheDocument();
    expect(screen.queryByText('Interstellar')).not.toBeInTheDocument();
    expect(screen.queryByText('Gladiator')).not.toBeInTheDocument();
  });

  it('filters movies by genre pill', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse({
        movies: [
          { filename: 'sci1.mkv', title: 'SciFi Movie', genres: 'Sci-Fi, Action', year: 2020, poster: 'tmdb:1', position: 0, duration: 0, percent: 0 },
          { filename: 'drama1.mkv', title: 'Drama Movie', genres: 'Drama', year: 2021, poster: 'tmdb:2', position: 0, duration: 0, percent: 0 },
        ] as MovieSummaryLive[],
        watching: [],
        total: 2,
      }),
    );

    renderLibrary();

    expect(await screen.findByText('SciFi Movie')).toBeInTheDocument();
    expect(screen.getByText('Drama Movie')).toBeInTheDocument();

    const sciFiPill = screen.getByRole('button', { name: 'Sci-Fi' });
    const { fireEvent } = await import('@testing-library/react');
    fireEvent.click(sciFiPill);

    expect(screen.getByText('SciFi Movie')).toBeInTheDocument();
    expect(screen.queryByText('Drama Movie')).not.toBeInTheDocument();
  });
});

describe('Upload Media placement', () => {
  it('covers the featured billboard with rich artwork', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse({
        movies: [
          {
            filename: 'epic.mkv',
            title: 'Epic',
            year: 2020,
            tmdb_id: 5,
            overview: 'A blockbuster with artwork.',
            poster: 'tmdb:5',
            position: 0,
            duration: 0,
            percent: 0,
          },
        ] as MovieSummaryLive[],
        watching: [],
        total: 1,
      }),
    );

    renderLibrary();

    expect(await screen.findByTestId('hero-spotlight')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /upload media/i })).toBeInTheDocument();
  });

  it('never overlaps the hero: the banner row displaces the negative-margin tuck', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse({
        movies: [
          {
            filename: 'epic.mkv',
            title: 'Epic',
            year: 2020,
            tmdb_id: 5,
            overview: 'A blockbuster with artwork.',
            poster: 'tmdb:5',
            position: 0,
            duration: 0,
            percent: 0,
          },
        ] as MovieSummaryLive[],
        watching: [],
        total: 1,
      }),
    );

    renderLibrary();

    const uploadButton = await screen.findByRole('button', { name: /upload media/i });
    const hero = screen.getByTestId('hero-spotlight');

    // The button row precedes the hero in document order.
    expect(
      uploadButton.compareDocumentPosition(hero) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();

    // The hero is no longer the page's first element, so it must not carry
    // the tucked variant's negative top margin (which pulled the artwork up
    // over this button row); it renders the banner variant instead.
    expect(hero.className).not.toMatch(/(^|\s)-mt-/);
    expect(hero.className).toMatch(/rounded-3xl/);
  });

  it('keeps the negative-margin header tuck available for a hero with nothing above it', () => {
    const movie = {
      filename: 'epic.mkv',
      title: 'Epic',
      year: 2020,
      tmdb_id: 5,
      overview: 'A blockbuster with artwork.',
      poster: 'tmdb:5',
      position: 0,
      duration: 0,
      percent: 0,
    } as MovieSummaryLive;

    render(
      <MemoryRouter>
        <HeroSpotlight movie={movie} hasTopBanner={false} />
      </MemoryRouter>,
    );

    const hero = screen.getByTestId('hero-spotlight');
    // The tucked variant (hero is the page's first element, sliding under
    // the sticky header) is unchanged: negative top margin, bottom-only
    // rounding.
    expect(hero.className).toMatch(/(^|\s)-mt-6(\s|$)/);
    expect(hero.className).toMatch(/rounded-b-3xl/);
    expect(hero.className).not.toMatch(/rounded-3xl(\s|$)/);
  });
});

/*
 * Issue 14.2 was reported as "the account icon is missing across pages", and
 * the first attempt at it added an `Avatar` to this page's Upload Media row.
 * The shared `AppShell` header already renders the affordance on every route
 * (and deliberately hides it on `/watch/*`, where a stray nav click would
 * interrupt playback), so that addition was a duplicate: signed out the page
 * showed the header's "Sign in" pill *and* a silhouette user icon on the next
 * row, and signed in it showed two avatars. This pins the correction: the
 * header owns the affordance, the page rows do not.
 */
describe('LibraryPage account affordance (Issue 14.2 correction)', () => {
  it('does not render a second account affordance beside Upload Media', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      if (String(input) === '/api/auth/me') {
        return jsonResponse({
          authenticated: true,
          email: 'owner@example.com',
          name: 'Anis Parvez',
          role: 'admin',
        });
      }
      return jsonResponse({ movies: [], watching: [], total: 0 });
    });

    /*
     * Wrapped in `AuthProvider` deliberately: without a provider, a re-added
     * `Avatar` would crash on `useAuth()` and fail this test for the wrong
     * reason. With one, it renders and the assertion below is what fails,
     * which states the actual regression.
     */
    render(
      <MemoryRouter>
        <AuthProvider>
          <LibraryPage />
        </AuthProvider>
      </MemoryRouter>,
    );

    await waitFor(() => {
      expect(screen.getByRole('status')).toHaveTextContent(/no movies found/i);
    });

    // `Avatar` renders `role="img"` labelled with the account name when it has
    // a signed-in identity.
    expect(screen.queryByRole('img', { name: /anis parvez/i })).toBeNull();

    // The row itself stays - it is the page's Upload Media action.
    expect(screen.getByRole('button', { name: /upload media/i })).toBeInTheDocument();
  });
});