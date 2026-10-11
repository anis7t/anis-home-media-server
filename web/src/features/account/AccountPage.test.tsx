import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { AuthProvider } from '../../auth/AuthProvider';
import { AccountPage } from './AccountPage';

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
  /*
   * Dispatch on URL rather than one blanket response. A single default would
   * hand the `/api/auth/me` shape to `/api/auth/tokens` as well, which is how
   * the first draft of this file produced a white screen.
   */
  fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
    if (String(input) === '/api/auth/me') {
      return jsonResponse({ authenticated: true, email: 'owner@example.com', role: 'admin' });
    }
    return jsonResponse({ tokens: [] });
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function renderAccount() {
  return render(
    <MemoryRouter>
      <AuthProvider>
        <AccountPage />
      </AuthProvider>
    </MemoryRouter>,
  );
}

describe('AccountPage', () => {
  it('shows the signed-in identity', async () => {
    renderAccount();
    expect(await screen.findByText('owner@example.com')).toBeInTheDocument();
  });

  it('lists existing devices with their status', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      if (String(input) === '/api/auth/me') {
        return jsonResponse({ authenticated: true, email: 'owner@example.com', role: 'admin' });
      }
      return jsonResponse({
        tokens: [
          {
            id: 1,
            user_id: 1,
            label: 'Living room TV',
            created_at: 1700000000,
            last_used_at: null,
            expires_at: null,
            revoked_at: null,
          },
        ],
      });
    });

    renderAccount();
    expect(await screen.findByText('Living room TV')).toBeInTheDocument();
    expect(screen.getByText('Active')).toBeInTheDocument();
  });

  it('marks a revoked device as revoked', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      if (String(input) === '/api/auth/me') {
        return jsonResponse({ authenticated: true, email: 'owner@example.com', role: 'admin' });
      }
      return jsonResponse({
        tokens: [
          {
            id: 1,
            user_id: 1,
            label: 'Old tablet',
            created_at: 1700000000,
            last_used_at: 1700000001,
            expires_at: null,
            revoked_at: 1700000002,
          },
        ],
      });
    });

    renderAccount();
    expect(await screen.findByText('Revoked')).toBeInTheDocument();
  });

  it('explains an empty device list rather than showing nothing', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      if (String(input) === '/api/auth/me') {
        return jsonResponse({ authenticated: true, email: 'owner@example.com', role: 'admin' });
      }
      return jsonResponse({ tokens: [] });
    });

    renderAccount();
    expect(await screen.findByText('No devices yet.')).toBeInTheDocument();
  });

  it('requires a label before minting', async () => {
    renderAccount();
    const button = await screen.findByRole('button', { name: /add device/i });
    expect(button).toBeDisabled();
  });

  it('mints a token and shows it once with its pairing link', async () => {
    const user = userEvent.setup();
    fetchMock.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url === '/api/auth/me') {
        return jsonResponse({ authenticated: true, email: 'owner@example.com', role: 'admin' });
      }
      if (init?.method === 'POST') {
        return jsonResponse(
          {
            token: 'ms_super_secret',
            pairing_url: 'https://host/auth/pair#ms_super_secret',
            id: 5,
            label: 'Living room TV',
            expires_at: null,
            warning: 'This token is displayed once and cannot be retrieved again.',
          },
          201,
        );
      }
      return jsonResponse({ tokens: [] });
    });

    renderAccount();
    await user.type(await screen.findByLabelText(/device name/i), 'Living room TV');
    await user.click(screen.getByRole('button', { name: /add device/i }));

    expect(await screen.findByText('ms_super_secret')).toBeInTheDocument();
    expect(
      screen.getByText('https://host/auth/pair#ms_super_secret'),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/displayed once and cannot be retrieved again/i),
    ).toBeInTheDocument();
  });

  it('can dismiss the one-time token panel', async () => {
    const user = userEvent.setup();
    fetchMock.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input) === '/api/auth/me') {
        return jsonResponse({ authenticated: true, email: 'owner@example.com', role: 'admin' });
      }
      if (init?.method === 'POST') {
        return jsonResponse(
          {
            token: 'ms_secret',
            pairing_url: 'https://host/auth/pair#ms_secret',
            id: 5,
            label: 'TV',
            expires_at: null,
            warning: 'This token is displayed once and cannot be retrieved again.',
          },
          201,
        );
      }
      return jsonResponse({ tokens: [] });
    });

    renderAccount();
    await user.type(await screen.findByLabelText(/device name/i), 'TV');
    await user.click(screen.getByRole('button', { name: /add device/i }));

    await screen.findByText('ms_secret');
    await user.click(screen.getByRole('button', { name: /i've saved it/i }));
    await waitFor(() => {
      expect(screen.queryByText('ms_secret')).not.toBeInTheDocument();
    });
  });

  it('revokes a device and reloads the list', async () => {
    const user = userEvent.setup();
    let listCalls = 0;
    fetchMock.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url === '/api/auth/me') {
        return jsonResponse({ authenticated: true, email: 'owner@example.com', role: 'admin' });
      }
      if (init?.method === 'DELETE') return jsonResponse({ revoked: 1 });
      listCalls += 1;
      return jsonResponse({
        tokens:
          listCalls === 1
            ? [
                {
                  id: 1,
                  user_id: 1,
                  label: 'Old TV',
                  created_at: 1700000000,
                  last_used_at: null,
                  expires_at: null,
                  revoked_at: null,
                },
              ]
            : [],
      });
    });

    renderAccount();
    await screen.findByText('Old TV');
    await user.click(screen.getByRole('button', { name: /revoke/i }));
    await waitFor(() => {
      expect(screen.getByText('No devices yet.')).toBeInTheDocument();
    });
  });

  it('hides device management from a non-admin', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      if (String(input) === '/api/auth/me') {
        return jsonResponse({ authenticated: true, email: 'viewer@example.com', role: 'viewer' });
      }
      return jsonResponse({ tokens: [] });
    });

    renderAccount();
    expect(await screen.findByText(/only an administrator can add devices/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /add device/i })).not.toBeInTheDocument();
  });

  it('surfaces a failure rather than silently showing an empty list', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      if (String(input) === '/api/auth/me') {
        return jsonResponse({ authenticated: true, email: 'owner@example.com', role: 'admin' });
      }
      return jsonResponse({ error: 'nope' }, 403);
    });

    renderAccount();
    expect(await screen.findByText(/request failed: 403/i)).toBeInTheDocument();
  });
});