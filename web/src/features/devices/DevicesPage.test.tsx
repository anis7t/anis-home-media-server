import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { DevicesPage } from './DevicesPage';

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: 'OK',
    json: async () => body,
  } as Response;
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);

  fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
    if (String(input) === '/api/devices') {
      return jsonResponse({
        current_device_id: 'dev_123',
        stats: {
          total_devices: 2,
          active_now: 1,
          offline: 1,
        },
        devices: [
          {
            device_id: 'dev_123',
            device_name: 'Chrome on Windows',
            display_name: 'Living Room PC',
            custom_name: 'Living Room PC',
            device_icon: '💻',
            device_type: 'Desktop',
            device_os: 'Windows 11',
            browser: 'Chrome 120',
            client_ip: '192.168.1.100',
            connection_type: 'Direct LAN',
            isp: 'Local ISP',
            city: 'Delhi',
            country: 'India',
            first_seen: '2026-10-10 10:00:00',
            last_seen: 'Just now',
            is_active: true,
            is_current: true,
            total_watched: 2,
            recent_watch: {
              filename: 'Inception.2010.mkv',
              title: 'Inception',
              year: '2010',
              position: 3600,
              duration: 8880,
              position_str: '1:00:00',
              duration_str: '2:28:00',
              percent: 40.5,
              completed: false,
              last_watched: '2026-10-14 18:00:00',
              last_watched_ago: '2 hours ago',
              poster_url: '/poster/Inception.2010.mkv',
            },
            watch_history: [
              {
                filename: 'Inception.2010.mkv',
                title: 'Inception',
                year: '2010',
                position: 3600,
                duration: 8880,
                position_str: '1:00:00',
                duration_str: '2:28:00',
                percent: 40.5,
                completed: false,
                last_watched: '2026-10-14 18:00:00',
                last_watched_ago: '2 hours ago',
                poster_url: '/poster/Inception.2010.mkv',
              },
              {
                filename: 'Interstellar.2014.mkv',
                title: 'Interstellar',
                year: '2014',
                position: 10140,
                duration: 10140,
                position_str: '2:49:00',
                duration_str: '2:49:00',
                percent: 100,
                completed: true,
                last_watched: '2026-10-13 21:00:00',
                last_watched_ago: '1 day ago',
                poster_url: '/poster/Interstellar.2014.mkv',
              },
            ],
          },
        ],
      });
    }
    if (String(input) === '/api/admin/verify') {
      return jsonResponse({ success: true, admin: true });
    }
    return jsonResponse({});
  });
});

afterEach(() => {
  sessionStorage.clear();
  vi.unstubAllGlobals();
});

function renderDevices() {
  return render(
    <MemoryRouter>
      <DevicesPage />
    </MemoryRouter>,
  );
}

describe('DevicesPage', () => {
  it('renders telemetry and educational callout explaining device pairing', async () => {
    renderDevices();
    expect(await screen.findByText('Client Devices & Telemetry')).toBeInTheDocument();
    expect(screen.getByText(/how device pairing & watch history work/i)).toBeInTheDocument();
    expect(screen.getByText('Living Room PC')).toBeInTheDocument();
    expect(screen.getByText('THIS BROWSER')).toBeInTheDocument();
    expect(screen.getByText(/unlock fleet telemetry/i)).toBeInTheDocument();
    expect(screen.getByText(/fleet privacy scoping active/i)).toBeInTheDocument();
  });

  it('opens and closes the portaled Watch History modal when clicking the button', async () => {
    const user = userEvent.setup();
    renderDevices();

    const historyBtn = await screen.findByRole('button', { name: /watch history/i });
    expect(historyBtn).toBeInTheDocument();

    await user.click(historyBtn);

    // Modal dialog rendered into portal
    const dialog = await screen.findByRole('dialog');
    expect(dialog).toBeInTheDocument();
    expect(within(dialog).getByText('Inception')).toBeInTheDocument();
    expect(within(dialog).getByText('Interstellar')).toBeInTheDocument();
    expect(within(dialog).getByText('Completed')).toBeInTheDocument();
    expect(within(dialog).getByText('40.5%')).toBeInTheDocument();

    // Close dialog
    const closeBtn = screen.getByRole('button', { name: /^close$/i });
    await user.click(closeBtn);

    await waitFor(() => {
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    });
  });

  it('unlocks fleet telemetry with valid Admin PIN', async () => {
    const user = userEvent.setup();
    renderDevices();

    const unlockFleetBtn = await screen.findByRole('button', { name: /unlock fleet telemetry/i });
    await user.click(unlockFleetBtn);

    const pinInput = screen.getByPlaceholderText(/admin pin…/i);
    expect(pinInput).toBeInTheDocument();

    await user.type(pinInput, '97531');
    const submitBtn = screen.getByRole('button', { name: /^Unlock Fleet$/i });
    await user.click(submitBtn);

    await waitFor(() => {
      expect(screen.getByText(/fleet admin view/i)).toBeInTheDocument();
    });
    expect(sessionStorage.getItem('ms_admin_pin')).toBe('97531');
  });

  it('passes AbortSignal to fetch and aborts on unmount', async () => {
    let capturedSignal: AbortSignal | undefined;
    fetchMock.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input) === '/api/devices') {
        capturedSignal = init?.signal as AbortSignal | undefined;
        return jsonResponse({
          current_device_id: 'dev_123',
          stats: { total_devices: 1, active_now: 1, offline: 0 },
          devices: [],
        });
      }
      return jsonResponse({});
    });

    const { unmount } = renderDevices();
    await waitFor(() => {
      expect(capturedSignal).toBeDefined();
    });
    expect(capturedSignal?.aborted).toBe(false);

    unmount();
    expect(capturedSignal?.aborted).toBe(true);
  });
});
