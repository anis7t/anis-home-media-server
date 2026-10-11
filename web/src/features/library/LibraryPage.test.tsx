import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { LibraryPage } from './LibraryPage';
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
    expect(await screen.findByRole('status')).toHaveTextContent(/no movies found/i);
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
});