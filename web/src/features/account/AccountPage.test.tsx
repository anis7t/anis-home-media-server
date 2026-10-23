import { render, screen } from '@testing-library/react';
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

const qrSession = {
  qr_id: 'qr_test',
  code: 'ABC12',
  sig: 'sig_test',
  expires_at: Math.floor(Date.now() / 1000) + 120,
  qr_url: 'https://host/auth/qr?code=ABC12&sig=sig_test',
  login_url: 'https://host/remote-login?code=ABC12',
};

let fetchMock: ReturnType<typeof vi.fn>;

function mockAuth(authenticated: boolean, extra: Record<string, unknown> = {}) {
  fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
    const url = String(input);
    if (url === '/api/auth/me') {
      return jsonResponse(
        authenticated
          ? {
              authenticated: true,
              email: 'owner@example.com',
              name: 'Anis Parvez',
              role: 'admin',
              ...extra,
            }
          : { authenticated: false, email: null, name: null, role: null, ...extra },
      );
    }
    if (url === '/api/auth/qr') return jsonResponse(qrSession);
    return jsonResponse({});
  });
}

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
  mockAuth(true);
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
  it('shows the guest mode status and sign in prompt when unauthenticated', async () => {
    mockAuth(false);

    renderAccount();
    expect(await screen.findByText('Guest Mode')).toBeInTheDocument();
    expect(screen.getByText('Not signed in · Browsing as a local guest')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /sign in with google →/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /sign in with admin pin/i })).toBeInTheDocument();
  });

  it('shows the signed-in identity', async () => {
    renderAccount();
    expect(await screen.findByText('Anis Parvez')).toBeInTheDocument();
    expect(await screen.findByText('owner@example.com')).toBeInTheDocument();
  });

  it('offers the QR sign-in card only to signed-out visitors', async () => {
    mockAuth(false);

    renderAccount();
    expect(
      await screen.findByRole('heading', { name: /sign in to anis' home media server/i }),
    ).toBeInTheDocument();
    expect(fetchMock.mock.calls.some((call) => String(call[0]) === '/api/auth/qr')).toBe(true);
  });

  it('does not create a QR session for an already signed-in visitor', async () => {
    renderAccount();
    await screen.findByText('Anis Parvez');

    expect(
      screen.queryByRole('heading', { name: /sign in to anis' home media server/i }),
    ).not.toBeInTheDocument();
    expect(fetchMock.mock.calls.some((call) => String(call[0]) === '/api/auth/qr')).toBe(false);
  });

  it('no longer renders the add-device / pairing-token panel', async () => {
    renderAccount();
    await screen.findByText('Anis Parvez');

    expect(screen.queryByRole('button', { name: /add device/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /sign in to pair/i })).not.toBeInTheDocument();
    expect(screen.queryByLabelText(/device name/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/devices & tv app pairing/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/pairing token/i)).not.toBeInTheDocument();

    const tokenCalls = fetchMock.mock.calls.filter(
      (call) => String(call[0]) === '/api/auth/tokens',
    );
    expect(tokenCalls).toHaveLength(0);
  });

  it('does not offer the removed add-device flow to signed-out visitors either', async () => {
    mockAuth(false);

    renderAccount();
    await screen.findByText('Guest Mode');

    expect(screen.queryByRole('button', { name: /add device/i })).not.toBeInTheDocument();
    expect(screen.queryByText(/pairing token/i)).not.toBeInTheDocument();
  });

  it('provides Admin PIN fallback and opens modal when OAuth is unconfigured', async () => {
    const user = userEvent.setup();
    mockAuth(false, { oauth_configured: false });

    renderAccount();
    expect(
      await screen.findByText(/Google Sign-In is not configured on this server/i),
    ).toBeInTheDocument();

    const pinButtons = screen.getAllByRole('button', { name: /sign in with admin pin/i });
    expect(pinButtons.length).toBeGreaterThan(0);

    // Clicking Admin PIN button opens the modal dialog
    await user.click(pinButtons[0]);
    expect(await screen.findByRole('dialog')).toBeInTheDocument();
    expect(screen.getByRole('heading', { level: 2, name: /Admin PIN Sign-In/i })).toBeInTheDocument();
  });
});
