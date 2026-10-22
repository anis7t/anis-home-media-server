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
  vi.restoreAllMocks();
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

const ADMIN_PIN = '97531';

const inceptionEntry = {
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
};

function device(overrides: Record<string, unknown> = {}) {
  return {
    device_id: 'dev_123',
    device_name: 'Chrome on Windows',
    display_name: 'Living Room PC',
    custom_name: null,
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
    is_current: false,
    total_watched: 1,
    recent_watch: null,
    watch_history: [inceptionEntry],
    owner: null,
    ...overrides,
  };
}

/** Admin view: two devices (one owned, one unowned) and two accounts. */
function mockAdminFetches() {
  fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
    const url = String(input);
    if (url === '/api/devices') {
      return jsonResponse({
        current_device_id: 'dev_123',
        stats: { total_devices: 2, active_now: 1, offline: 1 },
        devices: [
          device({
            device_id: 'dev_123',
            display_name: 'Living Room PC',
            is_current: true,
            owner: {
              id: 1,
              email: 'alice@example.test',
              name: 'Alice',
              role: 'viewer',
            },
          }),
          device({
            device_id: 'dev_456',
            display_name: 'Bedroom TV',
            is_active: false,
          }),
        ],
      });
    }
    if (url === '/api/admin/users') {
      return jsonResponse({
        users: [
          {
            id: 1,
            email: 'alice@example.test',
            name: 'Alice',
            role: 'viewer',
            created_at: '2026-10-01 10:00:00',
            last_login_at: null,
            device_count: 1,
            history_count: 1,
          },
          {
            id: 2,
            email: 'bob@example.test',
            name: 'Bob',
            role: 'admin',
            created_at: '2026-10-02 10:00:00',
            last_login_at: '2026-10-20 10:00:00',
            device_count: 1,
            history_count: 1,
          },
        ],
      });
    }
    return jsonResponse({ success: true });
  });
}

describe('DevicesPage admin oversight', () => {
  it('shows owner attribution, the account list and the admin controls', async () => {
    sessionStorage.setItem('ms_admin_pin', ADMIN_PIN);
    mockAdminFetches();

    renderDevices();

    expect(await screen.findByText('Accounts')).toBeInTheDocument();
    expect(screen.getAllByText(/alice@example\.test/).length).toBeGreaterThanOrEqual(1);
    expect(screen.getAllByText(/bob@example\.test/).length).toBeGreaterThanOrEqual(1);
    // The owned device shows its owner; the unowned one says so.
    expect(screen.getAllByText('Alice').length).toBeGreaterThanOrEqual(1);
    expect(screen.getAllByText('Unassigned').length).toBeGreaterThanOrEqual(1);
    // One control per device.
    expect(screen.getAllByRole('button', { name: 'Reassign' })).toHaveLength(2);
    expect(screen.getAllByRole('button', { name: /clear history/i })).toHaveLength(2);
    // Counts from /api/admin/users, not counted client-side.
    expect(screen.getAllByText(/1 device/)).toHaveLength(2);
  });

  it('reassigns a device to another account through the modal', async () => {
    sessionStorage.setItem('ms_admin_pin', ADMIN_PIN);
    mockAdminFetches();
    const user = userEvent.setup();

    renderDevices();

    const reassignButtons = await screen.findAllByRole('button', { name: 'Reassign' });
    await user.click(reassignButtons[0]);

    await user.selectOptions(screen.getByLabelText(/new device owner/i), '2');
    await user.click(screen.getByRole('button', { name: /^save$/i }));

    await waitFor(() => {
      expect(
        fetchMock.mock.calls.some(
          ([url]) => String(url) === '/api/admin/devices/assign',
        ),
      ).toBe(true);
    });
    const call = fetchMock.mock.calls.find(
      ([url]) => String(url) === '/api/admin/devices/assign',
    )!;
    expect(JSON.parse(String((call[1] as RequestInit).body))).toEqual({
      device_id: 'dev_123',
      user_id: 2,
    });
  });

  it('clears a device history only after confirmation', async () => {
    sessionStorage.setItem('ms_admin_pin', ADMIN_PIN);
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true);
    mockAdminFetches();
    const user = userEvent.setup();

    renderDevices();

    const clearButtons = await screen.findAllByRole('button', { name: /clear history/i });
    await user.click(clearButtons[0]);

    expect(confirmSpy).toHaveBeenCalled();
    await waitFor(() => {
      expect(
        fetchMock.mock.calls.some(
          ([url]) => String(url) === '/api/admin/devices/history/delete',
        ),
      ).toBe(true);
    });
    const call = fetchMock.mock.calls.find(
      ([url]) => String(url) === '/api/admin/devices/history/delete',
    )!;
    expect(JSON.parse(String((call[1] as RequestInit).body))).toEqual({
      device_id: 'dev_123',
    });
  });

  it('removes a single history entry from the history modal', async () => {
    sessionStorage.setItem('ms_admin_pin', ADMIN_PIN);
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    mockAdminFetches();
    const user = userEvent.setup();

    renderDevices();

    const historyButtons = await screen.findAllByRole('button', { name: /watch history/i });
    await user.click(historyButtons[0]);
    await user.click(
      screen.getByRole('button', { name: /remove inception from history/i }),
    );

    await waitFor(() => {
      expect(
        fetchMock.mock.calls.some(
          ([url]) => String(url) === '/api/admin/devices/history/delete',
        ),
      ).toBe(true);
    });
    const call = fetchMock.mock.calls.find(
      ([url]) => String(url) === '/api/admin/devices/history/delete',
    )!;
    expect(JSON.parse(String((call[1] as RequestInit).body))).toEqual({
      device_id: 'dev_123',
      filename: 'Inception.2010.mkv',
    });
  });

  it('does not expose the oversight surfaces to a non-admin', async () => {
    renderDevices();

    expect(await screen.findByText('Client Devices & Telemetry')).toBeInTheDocument();
    expect(screen.queryByText('Accounts')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Reassign' })).not.toBeInTheDocument();
    expect(
      fetchMock.mock.calls.some(([url]) => String(url) === '/api/admin/users'),
    ).toBe(false);
  });
});
