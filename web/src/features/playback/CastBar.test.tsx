import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { CastBar } from './CastBar';
import type { CastDevice, CastStatusResponse } from '../../lib/api/cast';

const mockDevice: CastDevice = {
  id: 'dlna:uuid-samsung-1',
  name: 'Living Room TV (Samsung QLED)',
  kind: 'dlna',
  model: 'Samsung QLED 4K',
  ip: '192.168.1.55',
};

const mockStatus: CastStatusResponse = {
  ok: true,
  state: 'playing',
  position: 125,
  duration: 3600,
  volume: 75,
  muted: false,
};

describe('CastBar', () => {
  it('renders active target device name, state, and timeline clock', () => {
    render(
      <CastBar
        device={mockDevice}
        filename="Interstellar.2014.mp4"
        status={mockStatus}
        onControl={vi.fn()}
        onDisconnect={vi.fn()}
      />,
    );

    expect(screen.getByRole('region', { name: /active cast remote controller/i })).toBeInTheDocument();
    expect(screen.getByText('Living Room TV (Samsung QLED)')).toBeInTheDocument();
    expect(screen.getByText('Interstellar.2014')).toBeInTheDocument();
    expect(screen.getByText('2:05')).toBeInTheDocument(); // 125s -> 2:05
    expect(screen.getByText('1:00:00')).toBeInTheDocument(); // 3600s -> 1:00:00
  });

  it('toggles play/pause command when button clicked', () => {
    const handleControl = vi.fn();

    const { rerender } = render(
      <CastBar
        device={mockDevice}
        filename="Interstellar.2014.mp4"
        status={mockStatus}
        onControl={handleControl}
        onDisconnect={vi.fn()}
      />,
    );

    // Currently playing -> click should send 'pause'
    const playPauseBtn = screen.getByRole('button', { name: /pause/i });
    fireEvent.click(playPauseBtn);
    expect(handleControl).toHaveBeenCalledWith('pause');

    // Rerender as paused -> click should send 'play'
    rerender(
      <CastBar
        device={mockDevice}
        filename="Interstellar.2014.mp4"
        status={{ ...mockStatus, state: 'paused' }}
        onControl={handleControl}
        onDisconnect={vi.fn()}
      />,
    );

    const playBtn = screen.getByRole('button', { name: /play/i });
    fireEvent.click(playBtn);
    expect(handleControl).toHaveBeenCalledWith('play');
  });

  it('triggers -10s and +10s seek commands', () => {
    const handleControl = vi.fn();

    render(
      <CastBar
        device={mockDevice}
        filename="Interstellar.2014.mp4"
        status={mockStatus}
        onControl={handleControl}
        onDisconnect={vi.fn()}
      />,
    );

    const backBtn = screen.getByRole('button', { name: /seek back 10s/i });
    fireEvent.click(backBtn);
    expect(handleControl).toHaveBeenCalledWith('seek', 115); // 125 - 10 = 115

    const forwardBtn = screen.getByRole('button', { name: /seek forward 10s/i });
    fireEvent.click(forwardBtn);
    expect(handleControl).toHaveBeenCalledWith('seek', 135); // 125 + 10 = 135
  });

  it('dispatches volume change and displays percentage', () => {
    const handleControl = vi.fn();

    render(
      <CastBar
        device={mockDevice}
        filename="Interstellar.2014.mp4"
        status={mockStatus}
        onControl={handleControl}
        onDisconnect={vi.fn()}
      />,
    );

    const volumeSlider = screen.getByRole('slider', { name: /remote volume/i });
    expect(document.getElementById('castVolumePercent')?.textContent).toBe('75%');
    expect(volumeSlider.style.background).toContain('75%');

    fireEvent.change(volumeSlider, { target: { value: '85' } });
    expect(handleControl).toHaveBeenCalledWith('volume', 85);
  });

  it('toggles mute when mute button clicked', () => {
    const handleControl = vi.fn();

    const { rerender } = render(
      <CastBar
        device={mockDevice}
        filename="Interstellar.2014.mp4"
        status={mockStatus}
        onControl={handleControl}
        onDisconnect={vi.fn()}
      />,
    );

    const muteBtn = screen.getByRole('button', { name: /mute/i });
    fireEvent.click(muteBtn);
    expect(handleControl).toHaveBeenCalledWith('mute', true);

    rerender(
      <CastBar
        device={mockDevice}
        filename="Interstellar.2014.mp4"
        status={{ ...mockStatus, muted: true }}
        onControl={handleControl}
        onDisconnect={vi.fn()}
      />,
    );

    const unmuteBtn = screen.getByRole('button', { name: /unmute/i });
    fireEvent.click(unmuteBtn);
    expect(handleControl).toHaveBeenCalledWith('mute', false);
  });

  it('renders subtitle selector and switches subtitle tracks', () => {
    const handleControl = vi.fn();
    const statusWithSubs: CastStatusResponse = {
      ...mockStatus,
      subtitles: [
        { track_id: 1, label: 'English [Original]', lang: 'en' },
        { track_id: 2, label: 'Spanish', lang: 'es' },
      ],
      active_subtitle_id: 1,
    };

    render(
      <CastBar
        device={mockDevice}
        filename="Interstellar.2014.mp4"
        status={statusWithSubs}
        onControl={handleControl}
        onDisconnect={vi.fn()}
      />,
    );

    const subBtn = screen.getByRole('button', { name: /cast subtitles/i });
    expect(subBtn).toBeInTheDocument();

    // Click to open menu
    fireEvent.click(subBtn);
    expect(screen.getByRole('menu', { name: /cast subtitles/i })).toBeInTheDocument();
    expect(screen.getByText('English [Original]')).toBeInTheDocument();
    expect(screen.getByText('Spanish')).toBeInTheDocument();
    expect(screen.getByText('Off')).toBeInTheDocument();

    // Select Spanish
    fireEvent.click(screen.getByText('Spanish'));
    expect(handleControl).toHaveBeenCalledWith('subtitle', 2);
  });

  it('renders a scrollable menu with track count when many subtitle tracks exist', () => {
    const manySubs = Array.from({ length: 37 }, (_, i) => ({
      track_id: i + 1,
      label: `Language Track ${i + 1}`,
      lang: `l${i + 1}`,
    }));
    const statusWithManySubs: CastStatusResponse = {
      ...mockStatus,
      subtitles: manySubs,
      active_subtitle_id: 1,
    };

    render(
      <CastBar
        device={mockDevice}
        filename="Spider-Man.mkv"
        status={statusWithManySubs}
        onControl={vi.fn()}
        onDisconnect={vi.fn()}
      />,
    );

    const subBtn = screen.getByRole('button', { name: /cast subtitles/i });
    fireEvent.click(subBtn);

    const menu = screen.getByRole('menu', { name: /cast subtitles/i });
    expect(menu).toHaveClass('overflow-y-auto');
    expect(menu).toHaveClass('custom-scrollbar');
    expect(screen.getByText('37 tracks')).toBeInTheDocument();
    expect(screen.getByText('Language Track 37')).toBeInTheDocument();
  });

  it('calls onDisconnect when disconnect button clicked', () => {
    const handleDisconnect = vi.fn();

    render(
      <CastBar
        device={mockDevice}
        filename="Interstellar.2014.mp4"
        status={mockStatus}
        onControl={vi.fn()}
        onDisconnect={handleDisconnect}
      />,
    );

    const disconnectBtn = screen.getByRole('button', { name: /disconnect cast/i });
    fireEvent.click(disconnectBtn);
    expect(handleDisconnect).toHaveBeenCalledTimes(1);
  });

  it('handles subtitle offset steppers (-50ms, +50ms) and reset in cast subtitle menu', () => {
    const handleControl = vi.fn();
    const statusWithSubs: CastStatusResponse = {
      ...mockStatus,
      subtitles: [
        { track_id: 1, label: 'English', lang: 'en' },
      ],
      active_subtitle_id: 1,
      subtitle_offset: 0.1,
    };

    render(
      <CastBar
        device={mockDevice}
        filename="Interstellar.2014.mp4"
        status={statusWithSubs}
        onControl={handleControl}
        onDisconnect={vi.fn()}
      />,
    );

    const subBtn = screen.getByRole('button', { name: /cast subtitles/i });
    fireEvent.click(subBtn);

    expect(screen.getByText('+0.10s')).toBeInTheDocument();

    const advanceBtn = screen.getByRole('button', { name: /-50ms/i });
    fireEvent.click(advanceBtn);
    expect(handleControl).toHaveBeenCalledWith('subtitle_offset', 0.05);

    const delayBtn = screen.getByRole('button', { name: /\+50ms/i });
    fireEvent.click(delayBtn);
    expect(handleControl).toHaveBeenCalledWith('subtitle_offset', 0.15);

    const resetBtn = screen.getByRole('button', { name: /reset/i });
    fireEvent.click(resetBtn);
    expect(handleControl).toHaveBeenCalledWith('subtitle_offset', 0);
  });
});
