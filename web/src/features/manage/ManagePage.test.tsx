import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { AuthProvider } from '../../auth/AuthProvider';
import { ManagePage } from './ManagePage';

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : 'Error',
    json: async () => body,
  } as Response;
}

let fetchMock: ReturnType<typeof vi.fn>;

const sampleMovies = [
  {
    filename: 'Matrix.1999.mkv',
    title: 'The Matrix',
    year: 1999,
    duration: 8160,
    position: 4000,
    percent: 49,
    poster: 'tmdb:603',
    hls_cached: true,
    needs_transcode: true,
  },
  {
    filename: 'Inception.2010.mp4',
    title: 'Inception',
    year: 2010,
    duration: 8880,
    position: 8880,
    percent: 100,
    poster: 'tmdb:27205',
    hls_cached: false,
    needs_transcode: false,
  },
];

const sampleSettings = {
  retention_policy: 'keep',
  archive_dir: 'D:/Flicks/.archive',
  allowed_policies: ['keep', 'archive', 'purge_cache'],
};

const sampleAudit = {
  storage: {
    free_str: '250.0 GB',
    total_str: '500.0 GB',
    percent: 50,
    drives: [
      {
        drive: 'E:',
        free_str: '100.0 GB',
        total_str: '200.0 GB',
        used_str: '100.0 GB',
        percent: 50,
      },
    ],
  },
  audit: {
    total_orphaned_dirs: 1,
    total_orphaned_bytes: 1048576,
    orphaned_hls_dirs: ['old_transcode'],
    total_active_dirs: 2,
    total_active_bytes: 209715200,
  },
};

beforeEach(() => {
  sessionStorage.clear();
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);

  fetchMock.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url === '/api/auth/me') {
      return jsonResponse({
        authenticated: false,
        email: null,
        name: null,
        role: 'viewer',
      });
    }
    if (url === '/api/movies') {
      return jsonResponse({ movies: sampleMovies });
    }
    if (url === '/api/storage/settings') {
      if (init?.method === 'POST') {
        return jsonResponse({ success: true, retention_policy: 'archive' });
      }
      return jsonResponse(sampleSettings);
    }
    if (url === '/api/storage/audit') {
      return jsonResponse(sampleAudit);
    }
    if (url === '/api/admin/verify') {
      const body = JSON.parse(String(init?.body || '{}'));
      if (body.pin === '6361') {
        return jsonResponse({ success: true, admin: true, method: 'pin' });
      }
      return jsonResponse({ success: false, error: 'Invalid Admin PIN' }, 401);
    }
    if (url.startsWith('/api/media/') && init?.method === 'DELETE') {
      return jsonResponse({ success: true, message: 'Purged' });
    }
    if (url === '/api/storage/purge-orphans') {
      return jsonResponse({ success: true, result: { purged: 1 } });
    }
    return jsonResponse({});
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function renderManage() {
  return render(
    <MemoryRouter>
      <AuthProvider>
        <ManagePage />
      </AuthProvider>
    </MemoryRouter>
  );
}

describe('ManagePage Comprehensive Edge Cases', () => {
  it('renders access-denied gate when not authenticated as admin, blocking settings & audit', async () => {
    renderManage();

    expect(await screen.findByText('Administrator Access Required')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /unlock with admin pin/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /sign in with google/i })).toBeInTheDocument();

    // Sensitive settings and drive audit must NOT be crawled while locked
    expect(fetchMock).not.toHaveBeenCalledWith(
      expect.stringContaining('/api/storage/settings'),
      expect.anything()
    );
    expect(fetchMock).not.toHaveBeenCalledWith(
      expect.stringContaining('/api/storage/audit'),
      expect.anything()
    );
  });

  it('filters movies by search query and category chips', async () => {
    sessionStorage.setItem('ms_admin_pin', '6361');
    sessionStorage.setItem('ms_admin_unlocked', 'true');

    renderManage();
    const user = userEvent.setup();

    await screen.findByText('The Matrix');

    // Filter by search query
    const searchInput = screen.getByPlaceholderText(/filter by title, filename, or year/i);
    await user.type(searchInput, 'Matrix');

    expect(screen.getByText('The Matrix')).toBeInTheDocument();
    expect(screen.queryByText('Inception')).not.toBeInTheDocument();

    // Clear search query
    await user.clear(searchInput);
    expect(screen.getByText('Inception')).toBeInTheDocument();

    // Filter by Direct play (Inception is .mp4)
    const directBtn = screen.getByRole('button', { name: /direct play/i });
    await user.click(directBtn);
    expect(screen.getByText('Inception')).toBeInTheDocument();
    expect(screen.queryByText('The Matrix')).not.toBeInTheDocument();

    // Filter by HLS (.mkv)
    const hlsBtn = screen.getByRole('button', { name: /hls \/ mkv/i });
    await user.click(hlsBtn);
    expect(screen.getByText('The Matrix')).toBeInTheDocument();
    expect(screen.queryByText('Inception')).not.toBeInTheDocument();
  });

  it('unlocks admin mode with valid PIN and updates badge', async () => {
    renderManage();
    const user = userEvent.setup();

    const unlockBtn = await screen.findByRole('button', { name: /unlock with admin pin/i });
    await user.click(unlockBtn);

    // Modal opens
    const pinInput = screen.getByPlaceholderText(/admin pin…/i);
    expect(pinInput).toBeInTheDocument();

    // Entering incorrect PIN displays error alert
    await user.type(pinInput, '0000');
    const submitBtn = screen.getByRole('button', { name: /^Unlock$/i });
    await user.click(submitBtn);

    expect(await screen.findByText(/invalid admin pin/i)).toBeInTheDocument();

    // Entering correct PIN succeeds
    await user.clear(pinInput);
    await user.type(pinInput, '6361');
    await user.click(submitBtn);

    await waitFor(() => {
      expect(screen.getByText(/admin verified/i)).toBeInTheDocument();
    });
    expect(screen.getByText('The Matrix')).toBeInTheDocument();
    expect(sessionStorage.getItem('ms_admin_pin')).toBe('6361');
    expect(sessionStorage.getItem('ms_admin_unlocked')).toBe('true');
  });

  it('prompts for PIN when deleting a movie while locked', async () => {
    // Admin role via Google session but PIN not entered yet
    fetchMock.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url === '/api/auth/me') {
        return jsonResponse({
          authenticated: true,
          email: 'admin@example.com',
          name: 'Admin',
          role: 'admin',
        });
      }
      if (url === '/api/movies') {
        return jsonResponse({ movies: sampleMovies });
      }
      if (url === '/api/storage/settings') {
        return jsonResponse(sampleSettings);
      }
      if (url === '/api/storage/audit') {
        return jsonResponse(sampleAudit);
      }
      if (url === '/api/admin/verify') {
        return jsonResponse({ success: true, admin: true, method: 'pin' });
      }
      if (url.startsWith('/api/media/') && init?.method === 'DELETE') {
        return jsonResponse({ success: true, message: 'Purged' });
      }
      return jsonResponse({});
    });

    renderManage();
    const user = userEvent.setup();

    await screen.findByText('The Matrix');

    // Click delete on The Matrix
    const deleteButtons = screen.getAllByRole('button', { name: /^delete$/i });
    await user.click(deleteButtons[0]);

    // Delete modal opens and prompts for PIN
    expect(await screen.findByRole('dialog')).toBeInTheDocument();
    expect(screen.getByText(/permanently delete & purge/i)).toBeInTheDocument();
    const modalPin = screen.getByPlaceholderText(/enter 4-digit pin…/i);
    expect(modalPin).toBeInTheDocument();

    // Enter PIN and confirm deletion
    await user.type(modalPin, '6361');
    const confirmDeleteBtn = screen.getByRole('button', { name: /yes, delete & purge everything/i });
    await user.click(confirmDeleteBtn);

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        expect.stringContaining('/api/media/Inception.2010.mp4'),
        expect.objectContaining({
          method: 'DELETE',
          headers: expect.objectContaining({ 'X-Admin-Pin': '6361' }),
        })
      );
    });
  });

  it('sends X-Admin-Pin when updating storage policy', async () => {
    sessionStorage.setItem('ms_admin_pin', '6361');
    sessionStorage.setItem('ms_admin_unlocked', 'true');

    renderManage();
    const user = userEvent.setup();

    await screen.findByText('The Matrix');

    // Click the "Move to Archive" policy card button
    const archivePolicyCard = screen.getByRole('button', { name: /move to archive/i });
    await user.click(archivePolicyCard);

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        '/api/storage/settings',
        expect.objectContaining({
          method: 'POST',
          headers: expect.objectContaining({ 'X-Admin-Pin': '6361' }),
          body: JSON.stringify({ retention_policy: 'archive' }),
        })
      );
    });
  });

  it('renders HLS Cached badge instantly from movie metadata even while storage audit is pending', async () => {
    sessionStorage.setItem('ms_admin_pin', '6361');
    sessionStorage.setItem('ms_admin_unlocked', 'true');

    // Delay /api/storage/audit to simulate a 10s drive crawl
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === '/api/auth/me') {
        return jsonResponse({ authenticated: false, email: null, name: null, role: 'viewer' });
      }
      if (url === '/api/movies') {
        return jsonResponse({ movies: sampleMovies });
      }
      if (url === '/api/storage/settings') {
        return jsonResponse(sampleSettings);
      }
      if (url === '/api/storage/audit') {
        // Return a pending promise that doesn't resolve immediately
        return new Promise((resolve) => {
          setTimeout(() => resolve(jsonResponse(sampleAudit)), 2000);
        });
      }
      return jsonResponse({});
    });

    renderManage();

    // The Matrix should be visible and immediately show "HLS Cached" without waiting for audit
    await screen.findByText('The Matrix');
    const hlsBadges = screen.getAllByText(/hls cached/i);
    expect(hlsBadges.length).toBeGreaterThanOrEqual(2);

    // And the storage pool section should show the auditing loading indicator
    expect(screen.getByText(/auditing storage pool & cache integrity/i)).toBeInTheDocument();
  });
});
