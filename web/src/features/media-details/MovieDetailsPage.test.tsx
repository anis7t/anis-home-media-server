import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { MovieDetailsPage } from './MovieDetailsPage';

const FILENAME = '2001 A Space Odyssey (1968) [BluRay]/2001.mkv';
const ROUTE = `/movie/${FILENAME.split('/').map(encodeURIComponent).join('/')}`;
const WATCH_HREF = `/watch/${FILENAME.split('/').map(encodeURIComponent).join('/')}`;

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
      genres: 'Science Fiction, Mystery, Adventure',
      release_date: '1968-04-02',
      position: 0,
      duration: 0,
      percent: 0,
    },
    specs: { resolution: '1080p', video_codec: 'h264', audio_codec: 'ac3' },
    formatted_runtime: '2h 29m',
    // The server sends this only when the title genuinely has backdrop
    // artwork; the page must render the fallback when it is null.
    backdrop_tmdb_id: 62,
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
      await screen.findByRole('heading', { name: '2001: A Space Odyssey', level: 1 }),
    ).toBeInTheDocument();
    // The meta row is a set of discrete, individually-labelled values rather
    // than one joined string, so each is asserted on its own.
    expect(screen.getByText('1968')).toBeInTheDocument();
    expect(screen.getByText('2h 29m')).toBeInTheDocument();
    expect(screen.getByText(/mysterious object/i)).toBeInTheDocument();
  });

  it('decodes the splat route back to the original path, keeping slashes', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      expect(decodeURIComponent(String(input))).toContain(
        '/api/movie/2001 A Space Odyssey (1968) [BluRay]/2001.mkv',
      );
      return jsonResponse(detailsPayload());
    });

    renderPage();
    await screen.findByRole('heading', { name: '2001: A Space Odyssey', level: 1 });
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

  /**
   * Regression: `GET /api/movie/<file>` sends `extended` as an **object**
   * (`app/routes/api.py` parses `details_json` server-side). The page used to
   * accept only the JSON *string*, so every extended field silently vanished -
   * no tagline, no cast, no director - with no error anywhere. Assert on the
   * object shape, because that is what the server actually sends.
   */
  it('reads extended metadata when the server sends it as an object', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse(
        detailsPayload({
          extended: {
            tagline: 'An epic drama of adventure.',
            certification: 'G',
            directors: ['Stanley Kubrick'],
            writers: ['Arthur C. Clarke'],
            production: ['Metro-Goldwyn-Mayer'],
            cast: [
              { name: 'Keir Dullea', character: 'Dr. David Bowman', profile_path: '/a.jpg' },
              { name: 'Gary Lockwood', character: 'Dr. Frank Poole', profile_path: '/b.jpg' },
            ],
          },
        }),
      ),
    );

    renderPage();

    expect(await screen.findByText(/epic drama of adventure/i)).toBeInTheDocument();
    expect(screen.getByText('G')).toBeInTheDocument();
    expect(screen.getByText('Stanley Kubrick')).toBeInTheDocument();
    expect(screen.getByText('Arthur C. Clarke')).toBeInTheDocument();
    expect(screen.getByText('Metro-Goldwyn-Mayer')).toBeInTheDocument();

    const rail = await screen.findByRole('list', { name: /top billed cast/i });
    expect(within(rail).getByText('Keir Dullea')).toBeInTheDocument();
    expect(within(rail).getByText('Dr. David Bowman')).toBeInTheDocument();
  });

  it('renders genres as separate chips', async () => {
    fetchMock.mockImplementation(async () => jsonResponse(detailsPayload()));

    renderPage();

    const genres = await screen.findByRole('list', { name: /genres/i });
    expect(within(genres).getByText('Science Fiction')).toBeInTheDocument();
    expect(within(genres).getByText('Mystery')).toBeInTheDocument();
    expect(within(genres).getByText('Adventure')).toBeInTheDocument();
  });

  it('renders the technical specs the legacy page showed', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse(
        detailsPayload({
          specs: {
            resolution: '4K 2160p',
            resolution_badge: '4K',
            video_codec: 'HEVC (H.265)',
            audio_codec: 'Dolby Digital Plus',
            audio_channels: '5.1 Surround',
            container: 'MKV',
            file_size: '18.4 GB',
            bitrate: '42.1 Mbps',
            aspect_ratio: '2.39:1',
            subtitles: ['English (SRT)', 'English (OpenSubtitles)'],
          },
        }),
      ),
    );

    renderPage();

    expect(await screen.findByText('4K 2160p')).toBeInTheDocument();
    expect(screen.getByText('HEVC (H.265)')).toBeInTheDocument();
    expect(screen.getByText('Dolby Digital Plus')).toBeInTheDocument();
    expect(screen.getByText('5.1 Surround')).toBeInTheDocument();
    expect(screen.getByText('MKV')).toBeInTheDocument();
    expect(screen.getByText('18.4 GB')).toBeInTheDocument();
    expect(screen.getByText('42.1 Mbps')).toBeInTheDocument();
    expect(screen.getByText('2 tracks')).toBeInTheDocument();
  });

  it('degrades gracefully when extended is malformed', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse(detailsPayload({ extended: '{not valid json' })),
    );

    renderPage();
    // Must still render the page rather than throwing on the parse.
    expect(
      await screen.findByRole('heading', { name: '2001: A Space Odyssey', level: 1 }),
    ).toBeInTheDocument();
  });

  it('requests the backdrop with high fetch priority as the page LCP', async () => {
    fetchMock.mockImplementation(async () => jsonResponse(detailsPayload()));

    renderPage();

    const backdrop = await screen.findByRole('presentation', { hidden: true });
    expect(backdrop).toHaveAttribute('fetchpriority', 'high');
  });

  /**
   * Regression: the server sends `backdrop_tmdb_id: null` for titles with no
   * backdrop artwork. Building the URL from `movie.tmdb_id` instead requests an
   * image that does not exist - a 404 for every such title - instead of
   * falling back.
   */
  it('does not request a backdrop the server says does not exist', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse(detailsPayload({ backdrop_tmdb_id: null })),
    );

    renderPage();

    await screen.findByRole('heading', { name: '2001: A Space Odyssey', level: 1 });
    expect(screen.queryByRole('presentation', { hidden: true })).not.toBeInTheDocument();
    // The page still renders its content without the artwork.
    expect(screen.getByTestId('play-button')).toBeInTheDocument();
  });

  it('links to the player with the filename preserved', async () => {
    fetchMock.mockImplementation(async () => jsonResponse(detailsPayload()));

    renderPage();

    const play = await screen.findByTestId('play-button');
    expect(play).toHaveAttribute('href', WATCH_HREF);
  });

  it('offers Resume once a position has been saved', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse(
        detailsPayload({
          movie: { ...detailsPayload().movie, position: 1200 },
        }),
      ),
    );

    renderPage();

    const play = await screen.findByTestId('play-button');
    expect(play).toHaveTextContent(/resume/i);
    expect(play).toHaveAttribute('href', WATCH_HREF);
  });

  it('links to Replay with an explicit replay flag', async () => {
    fetchMock.mockImplementation(async () => jsonResponse(detailsPayload()));

    renderPage();

    const replay = await screen.findByRole('link', { name: /replay/i });
    expect(replay).toHaveAttribute('href', `${WATCH_HREF}?replay=1`);
  });

  it('navigates to the player route on click', async () => {
    const user = userEvent.setup();
    fetchMock.mockImplementation(async () => jsonResponse(detailsPayload()));

    renderPage();
    await user.click(await screen.findByTestId('play-button'));

    await waitFor(() => {
      expect(screen.getByTestId('player-route')).toBeInTheDocument();
    });
  });

  it('opens the trailer in a dialog and does not preload the player', async () => {
    const user = userEvent.setup();
    fetchMock.mockImplementation(async () =>
      jsonResponse(detailsPayload({ extended: { trailer_key: 'kR2r-A9H3Kg' } })),
    );

    renderPage();

    // No trailer dialog exists at all unless the title actually has a trailer.
    const withoutTrailer = screen.queryByRole('dialog');
    expect(withoutTrailer).not.toBeInTheDocument();

    const trailer = await screen.findByRole('button', { name: /trailer/i });
    await user.click(trailer);

    const dialog = await screen.findByRole('dialog');
    expect(dialog).toHaveAttribute('open');
    const frame = within(dialog).getByTitle(/trailer for/i);
    expect(frame).toHaveAttribute(
      'src',
      expect.stringContaining('youtube-nocookie.com/embed/kR2r-A9H3Kg'),
    );
  });
});