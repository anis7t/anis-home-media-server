import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { AuthProvider } from '../../auth/AuthProvider';
import { TranscodeDashboardPage } from './TranscodeDashboardPage';

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : 'Error',
    json: async () => body,
  } as Response;
}

let fetchMock: ReturnType<typeof vi.fn>;

const sampleDashboardData = {
  summary: {
    active_count: 1,
    running_count: 1,
    queued_count: 0,
    total_current_bytes: 524288000,
    total_current_size_str: '500.00 MB',
    total_estimated_bytes: 2147483648,
    total_estimated_size_str: '~2.0 GB',
    overall_eta_seconds: 180,
    overall_eta_str: '3m 0s',
    hardware_engine: {
      primary: {
        name: 'AMD Radeon RX 560X',
        adapter: 1,
        backend: 'D3D11VA',
        status: 'Active Encoding',
      },
      secondary: {
        name: 'AMD Radeon Vega 8',
        adapter: 0,
        backend: 'D3D11VA',
        status: 'Active Encoding',
      },
    },
  },
  active_jobs: [
    {
      id: 1,
      filename: 'The.Matrix.1999.mkv',
      title: 'The Matrix',
      year: 1999,
      runtime: 136,
      mode: 'hevc_nvenc',
      preset_label: '1080p fMP4',
      status: 'running' as const,
      percent: 45.5,
      speed_str: '2.4x',
      fps_str: '58 fps',
      eta_str: '2m 15s',
      encoded_str: '1:02:14',
      duration_str: '2:16:18',
      current_bytes: 524288000,
      current_size_str: '500 MB',
      estimated_total_bytes: 2147483648,
      estimated_total_size_str: '~2.0 GB',
      priority: 10,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
  ],
  recent_jobs: [],
};

beforeEach(() => {
  sessionStorage.clear();
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function renderDashboard() {
  return render(
    <MemoryRouter>
      <AuthProvider>
        <TranscodeDashboardPage />
      </AuthProvider>
    </MemoryRouter>
  );
}

describe('TranscodeDashboardPage Auth & Null Safety Transitions', () => {
  it('renders AdminAccessGate when user is not an administrator', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === '/api/auth/me') {
        return jsonResponse({
          authenticated: false,
          email: null,
          name: null,
          role: null,
        });
      }
      return jsonResponse({});
    });

    renderDashboard();

    expect(await screen.findByText('Administrator Access Required')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /unlock with admin pin/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /sign in with google/i })).toBeInTheDocument();
  });

  it('renders loading state without throwing TypeError during auth transition while data is pending', async () => {
    let resolveDashboard: (val: unknown) => void = () => {};
    const dashboardPromise = new Promise((resolve) => {
      resolveDashboard = resolve;
    });

    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === '/api/auth/me') {
        return jsonResponse({
          authenticated: true,
          email: 'admin@media.internal',
          name: 'Admin User',
          role: 'admin',
        });
      }
      if (url === '/api/transcode/dashboard') {
        await dashboardPromise;
        return jsonResponse(sampleDashboardData);
      }
      return jsonResponse({});
    });

    renderDashboard();

    // The loading spinner must display without throwing any "Cannot read properties of undefined"
    expect(
      await screen.findByText(/connecting to transcoding command center/i)
    ).toBeInTheDocument();

    // Now resolve dashboard data
    resolveDashboard(sampleDashboardData);

    // Dashboard should transition smoothly to populated state
    expect(await screen.findByText('Transcoding Command Center')).toBeInTheDocument();
    expect(screen.getByText('RX 560X (dx11:1)')).toBeInTheDocument();
    expect(screen.getByText('Vega 8 (dx11:0)')).toBeInTheDocument();
  });

  it('renders hardware engine statuses and active jobs cleanly when data is loaded', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === '/api/auth/me') {
        return jsonResponse({
          authenticated: true,
          email: 'admin@media.internal',
          name: 'Admin User',
          role: 'admin',
        });
      }
      if (url === '/api/transcode/dashboard') {
        return jsonResponse(sampleDashboardData);
      }
      return jsonResponse({});
    });

    renderDashboard();

    expect(await screen.findByText('Transcoding Command Center')).toBeInTheDocument();
    expect(screen.getByText('The Matrix')).toBeInTheDocument();
    expect(screen.getByText('45.5% Completed')).toBeInTheDocument();

    // Hardware status checks
    const activeEncoders = screen.getAllByText('Active Encoding');
    expect(activeEncoders.length).toBeGreaterThanOrEqual(2);
  });

  it('renders error card with retry button when initial dashboard fetch fails', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === '/api/auth/me') {
        return jsonResponse({
          authenticated: true,
          email: 'admin@media.internal',
          name: 'Admin User',
          role: 'admin',
        });
      }
      if (url === '/api/transcode/dashboard' || url === '/api/transcodes') {
        return jsonResponse({ error: 'Server transcode engine offline' }, 500);
      }
      return jsonResponse({});
    });

    renderDashboard();

    expect(await screen.findByText('Failed to load Transcode Dashboard')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /retry connection/i })).toBeInTheDocument();
  });
});
