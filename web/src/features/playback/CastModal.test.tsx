import { fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CastModal } from './CastModal';
import type { CastDevice } from '../../lib/api/cast';

const mockDevices: CastDevice[] = [
  {
    id: 'dlna:uuid-samsung-1',
    name: 'Living Room TV',
    kind: 'dlna',
    model: 'Samsung QLED 4K',
    ip: '192.168.1.55',
  },
  {
    id: 'cast:uuid-chromecast-2',
    name: 'Bedroom TV',
    kind: 'cast',
    model: 'Chromecast with Google TV',
    ip: '192.168.1.60',
  },
];

let fetchMock: ReturnType<typeof vi.fn>;

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : 'Error',
    json: async () => body,
  } as Response;
}

beforeEach(() => {
  fetchMock = vi.fn().mockResolvedValue(jsonResponse({ ok: true, devices: mockDevices }));
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('CastModal', () => {
  it('renders device list when opened and fetches LAN devices', async () => {
    const handleSelect = vi.fn();
    const handleClose = vi.fn();

    render(
      <CastModal
        open={true}
        onClose={handleClose}
        onSelectDevice={handleSelect}
      />,
    );

    expect(screen.getByRole('dialog', { name: /cast to device/i })).toBeInTheDocument();
    expect(await screen.findByText('Living Room TV')).toBeInTheDocument();
    expect(screen.getByText('Bedroom TV')).toBeInTheDocument();
    expect(screen.getByText('192.168.1.55')).toBeInTheDocument();
  });

  it('selects device on click', async () => {
    const handleSelect = vi.fn();
    const handleClose = vi.fn();

    render(
      <CastModal
        open={true}
        onClose={handleClose}
        onSelectDevice={handleSelect}
      />,
    );

    const tvButton = await screen.findByRole('button', { name: /living room tv/i });
    fireEvent.click(tvButton);

    expect(handleSelect).toHaveBeenCalledWith(mockDevices[0]);
  });

  it('renders empty state when no devices are found', async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ ok: true, devices: [] }));

    render(
      <CastModal
        open={true}
        onClose={vi.fn()}
        onSelectDevice={vi.fn()}
      />,
    );

    expect(await screen.findByText(/no playback devices found/i)).toBeInTheDocument();
  });

  it('closes on Escape key press', async () => {
    const handleClose = vi.fn();

    render(
      <CastModal
        open={true}
        onClose={handleClose}
        onSelectDevice={vi.fn()}
      />,
    );

    fireEvent.keyDown(window, { key: 'Escape' });
    expect(handleClose).toHaveBeenCalledTimes(1);
  });

  it('shows active device indicator and triggers disconnect', async () => {
    const handleDisconnect = vi.fn();

    render(
      <CastModal
        open={true}
        onClose={vi.fn()}
        onSelectDevice={vi.fn()}
        onDisconnectDevice={handleDisconnect}
        activeDeviceId="dlna:uuid-samsung-1"
      />,
    );

    expect(await screen.findByText(/currently casting/i)).toBeInTheDocument();
    const disconnectBtn = screen.getByRole('button', { name: /disconnect/i });
    fireEvent.click(disconnectBtn);

    expect(handleDisconnect).toHaveBeenCalledTimes(1);
  });

  it('polls for devices while scanning flag is true on rescan', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ ok: true, devices: [], scanning: true }))
      .mockResolvedValueOnce(jsonResponse({ ok: true, devices: mockDevices, scanning: false }));

    render(
      <CastModal
        open={true}
        onClose={vi.fn()}
        onSelectDevice={vi.fn()}
      />,
    );

    // Initial fetch triggers scanning: true
    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        expect.stringContaining('/api/cast/devices'),
        expect.any(Object),
      );
    });

    // Advance 1s to trigger poll
    await vi.advanceTimersByTimeAsync(1000);

    await vi.waitFor(() => {
      expect(screen.getByText('Living Room TV')).toBeInTheDocument();
    });

    vi.useRealTimers();
  });
});
