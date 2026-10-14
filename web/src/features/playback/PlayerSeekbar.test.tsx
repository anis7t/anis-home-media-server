import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PlayerSeekbar } from './PlayerSeekbar';

describe('PlayerSeekbar component', () => {
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchMock = vi.fn().mockResolvedValue({
      ok: false,
      json: async () => null,
    });
    vi.stubGlobal('fetch', fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('renders seek rail, played progress bar, and range input', () => {
    const handleSeek = vi.fn();
    render(
      <PlayerSeekbar
        filename="TestMovie.mp4"
        duration={100}
        currentTime={25}
        onSeek={handleSeek}
      />
    );

    const seekInput = screen.getByRole('slider', { name: /seek/i });
    expect(seekInput).toBeInTheDocument();
    expect(seekInput).toHaveValue('25');

    const played = document.getElementById('seekPlayed');
    expect(played).toHaveStyle({ width: '25%' });
  });

  it('loads seek-preview-meta and displays hover preview thumbnail when canPreview is true', async () => {
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        duration: 100,
        interval: 10,
        count: 10,
        base_url: '/seek-preview/TestMovie.mp4',
      }),
    });

    const handleSeek = vi.fn();
    render(
      <PlayerSeekbar
        filename="TestMovie.mp4"
        duration={100}
        currentTime={0}
        onSeek={handleSeek}
        canPreview={true}
      />
    );

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        expect.stringContaining('/api/seek-preview-meta/TestMovie.mp4'),
        expect.anything()
      );
    });

    const track = document.getElementById('seekTrack');
    expect(track).toBeInTheDocument();

    // Trigger mouse move to 30% of width
    vi.spyOn(track!, 'getBoundingClientRect').mockReturnValue({
      left: 0,
      top: 0,
      width: 1000,
      height: 28,
      right: 1000,
      bottom: 28,
      x: 0,
      y: 0,
      toJSON: () => {},
    });

    fireEvent.mouseMove(track!, { clientX: 300 });

    const preview = document.getElementById('seekPreview');
    expect(preview).toBeInTheDocument();
    expect(preview).not.toHaveAttribute('hidden');
    expect(preview).toHaveTextContent('0:30');
  });

  it('does NOT fetch preview metadata or show preview when canPreview is false', async () => {
    const handleSeek = vi.fn();
    render(
      <PlayerSeekbar
        filename="Transcoding.mkv"
        duration={100}
        currentTime={0}
        onSeek={handleSeek}
        canPreview={false}
      />
    );

    // Give any stray fetch a chance to run
    await new Promise((r) => setTimeout(r, 30));
    expect(fetchMock).not.toHaveBeenCalled();

    const preview = document.getElementById('seekPreview');
    expect(preview).not.toBeInTheDocument();
  });

  it('displays frame preview during scrub drag even when video is paused', async () => {
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        duration: 100,
        interval: 5,
        count: 20,
        base_url: '/seek-preview/Movie.mp4',
      }),
    });

    const handleSeek = vi.fn();
    const handleScrub = vi.fn();
    render(
      <PlayerSeekbar
        filename="Movie.mp4"
        duration={100}
        currentTime={10}
        onSeek={handleSeek}
        onScrubbingChange={handleScrub}
        canPreview={true}
      />
    );

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalled();
    });

    const track = document.getElementById('seekTrack');
    vi.spyOn(track!, 'getBoundingClientRect').mockReturnValue({
      left: 0,
      top: 0,
      width: 1000,
      height: 28,
      right: 1000,
      bottom: 28,
      x: 0,
      y: 0,
      toJSON: () => {},
    });

    const seekInput = screen.getByRole('slider', { name: /seek/i });

    // Pointer down on slider (drag start)
    fireEvent.pointerDown(seekInput, { clientX: 600 });
    expect(handleScrub).toHaveBeenCalledWith(true);

    const preview = document.getElementById('seekPreview');
    expect(preview).toBeInTheDocument();
    expect(preview).toHaveTextContent('1:00');

    // Pointer up commits seek
    fireEvent.pointerUp(seekInput, { target: { value: '60' } });
    expect(handleSeek).toHaveBeenCalledWith(60);
    expect(handleScrub).toHaveBeenCalledWith(false);
  });
});
