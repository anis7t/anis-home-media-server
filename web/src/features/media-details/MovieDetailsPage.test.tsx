import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { MovieDetailsPage } from './MovieDetailsPage';

const FILENAME = '2001 A Space Odyssey (1968) [BluRay]/2001.mkv';
const ROUTE = `/movie/${FILENAME.split('/').map(encodeURIComponent).join('/')}`;

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : 'Error',
    json: async () => body,
  } as Response;
}

let fetchMock: ReturnType<typeof vi.fn>;

function detailsPayload(overrides: Record<string, unknown> = {}) {
  return {
    movie: {
      filename: FILENAME,
      title: '2001: A Space Odyssey',
      year: 1968,
      tmdb_id: 62,
      poster: 'tmdb:62',
      overview: 'Humanity finds a mysterious object.',
      position: 0,
      duration: 0,
      percent: 0,
    },
    specs: { resolution: '1080p', video_codec: 'h264', audio_codec: 'ac3' },
    formatted_runtime: '2h 29m',
    needs_transcode: false,
    is_transcode_ready: false,
    ...overrides,
  };
}

function renderPage() {
  return render(
    <MemoryRouter initialEntries={[ROUTE]}>
      <Routes>
        <Route path="/movie/*" element={<MovieDetailsPage />} />
        <Route path="/watch/*" element={<div data-testid="player-route" />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('MovieDetailsPage', () => {
  it('renders the title, year, runtime and overview from the contract', async () => {
    fetchMock.mockImplementation(async () => jsonResponse(detailsPayload()));

    renderPage();

    expect(
      await screen.findByRole('heading', { name: '2001: A Space Odyssey' }),
    ).toBeInTheDocument();
    expect(screen.getByText(/1968 · 1080p · 2h 29m/)).toBeInTheDocument();
    expect(screen.getByText(/mysterious object/i)).toBeInTheDocument();
  });

  it('decodes the splat route back to the original path, keeping slashes', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      // The request URL must contain the whole nested path, not just the
      // basename - this is the <path:filename> equivalent on the client.
      expect(decodeURIComponent(String(input))).toContain('/api/movie/2001 A Space Odyssey (1968) [BluRay]/2001.mkv');
      return jsonResponse(detailsPayload());
    });

    renderPage();
    await screen.findByRole('heading', { name: '2001: A Space Odyssey' });
  });

  it('parses the raw details_json string into a tagline', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse(
        detailsPayload({ extended: JSON.stringify({ tagline: 'An epic drama of adventure.' }) }),
      ),
    );

    renderPage();
    expect(await screen.findByText(/epic drama of adventure/i)).toBeInTheDocument();
  });

  it('degrades gracefully when details_json is malformed', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse(detailsPayload({ extended: '{not valid json' })),
    );

    renderPage();
    // Must still render the page rather than throwing on the parse.
    expect(
      await screen.findByRole('heading', { name: '2001: A Space Odyssey' }),
    ).toBeInTheDocument();
  });

  it('requests the backdrop with high fetch priority as the page LCP', async () => {
    fetchMock.mockImplementation(async () => jsonResponse(detailsPayload()));

    renderPage();

    const backdrop = await screen.findByRole('presentation', { hidden: true });
    expect(backdrop).toHaveAttribute('fetchpriority', 'high');
  });

  it('links to the player with the filename preserved', async () => {
    fetchMock.mockImplementation(async () => jsonResponse(detailsPayload()));

    renderPage();

    const play = await screen.findByRole('link', { name: /play/i });
    expect(play).toHaveAttribute('href', `/watch/${FILENAME.split('/').map(encodeURIComponent).join('/')}`);
  });

  it('navigates to the player route on click', async () => {
    const user = userEvent.setup();
    fetchMock.mockImplementation(async () => jsonResponse(detailsPayload()));

    renderPage();
    await user.click(await screen.findByRole('link', { name: /play/i }));

    await waitFor(() => {
      expect(screen.getByTestId('player-route')).toBeInTheDocument();
    });
  });
});