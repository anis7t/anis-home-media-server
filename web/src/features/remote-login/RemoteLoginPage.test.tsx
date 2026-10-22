import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { RemoteLoginPage } from './RemoteLoginPage';
import { confirmQrSession, lookupQrCode } from '../../lib/api/account';

vi.mock('../../lib/api/account', () => ({
  confirmQrSession: vi.fn(),
  lookupQrCode: vi.fn(),
}));

const mockedConfirm = vi.mocked(confirmQrSession);
const mockedLookup = vi.mocked(lookupQrCode);

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: 'OK',
    json: async () => body,
  } as Response;
}

let fetchMock: ReturnType<typeof vi.fn>;

/** Set the page's query string without navigating. */
function setSearch(search: string) {
  window.history.pushState({}, '', `/remotelogin${search}`);
}

function mockAuth(authenticated: boolean) {
  fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
    if (String(input) === '/api/auth/me') {
      return jsonResponse({
        authenticated,
        email: authenticated ? 'owner@example.com' : null,
        name: authenticated ? 'Anis Parvez' : null,
        role: authenticated ? 'admin' : null,
      });
    }
    return jsonResponse({});
  });
}

beforeEach(() => {
  mockedConfirm.mockReset();
  mockedLookup.mockReset();
  mockedConfirm.mockResolvedValue({ success: true, message: 'ok' });
  mockedLookup.mockResolvedValue({ qr_id: 'qr_test_1', code: 'K7R2P' });

  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
  setSearch('');
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('RemoteLoginPage', () => {
  it('asks an unauthenticated visitor to sign in first', async () => {
    mockAuth(false);
    render(<RemoteLoginPage />);

    expect(await screen.findByText('Sign in first')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /continue with google/i })).toHaveAttribute(
      'href',
      expect.stringContaining('/auth/google'),
    );
  });

  it('preserves the QR parameters through the Google sign-in redirect', async () => {
    mockAuth(false);
    setSearch('?qr_id=qr_test_1&code=K7R2P&sig=deadbeef');
    render(<RemoteLoginPage />);

    const link = await screen.findByRole('link', { name: /continue with google/i });
    const href = decodeURIComponent(link.getAttribute('href') ?? '');
    expect(href).toContain('qr_id=qr_test_1');
    expect(href).toContain('code=K7R2P');
    expect(href).toContain('sig=deadbeef');
  });

  it('skips code entry when the visitor arrived by scanning the QR code', async () => {
    mockAuth(true);
    setSearch('?qr_id=qr_test_1&code=K7R2P&sig=deadbeef');
    render(<RemoteLoginPage />);

    expect(await screen.findByText('Name this device')).toBeInTheDocument();
    expect(mockedLookup).not.toHaveBeenCalled();
  });

  it('asks for the code when there are no QR parameters', async () => {
    mockAuth(true);
    render(<RemoteLoginPage />);

    expect(await screen.findByText('Enter pairing code')).toBeInTheDocument();
  });

  it('resolves a manually entered code and moves on to naming the device', async () => {
    const user = userEvent.setup();
    mockAuth(true);
    render(<RemoteLoginPage />);

    await screen.findByText('Enter pairing code');

    for (const [index, digit] of ['K', '7', 'R', '2', 'P'].entries()) {
      await user.type(screen.getByLabelText(`Code digit ${index + 1}`), digit);
    }

    await waitFor(() => expect(mockedLookup).toHaveBeenCalledWith('K7R2P'));
    expect(await screen.findByText('Name this device')).toBeInTheDocument();
  });

  it('confirms the pairing with the chosen device name', async () => {
    const user = userEvent.setup();
    mockAuth(true);
    setSearch('?qr_id=qr_test_1&code=K7R2P&sig=deadbeef');
    render(<RemoteLoginPage />);

    await screen.findByText('Name this device');
    await user.click(screen.getByRole('button', { name: 'Living room TV' }));
    await user.click(screen.getByRole('button', { name: /pair device/i }));

    await waitFor(() =>
      expect(mockedConfirm).toHaveBeenCalledWith('qr_test_1', 'Living room TV', {
        code: 'K7R2P',
        sig: 'deadbeef',
      }),
    );
    expect(await screen.findByText('All done!')).toBeInTheDocument();
    expect(screen.getByText(/living room tv/i)).toBeInTheDocument();
  });

  it('surfaces a rejected code instead of advancing', async () => {
    const user = userEvent.setup();
    mockAuth(true);
    mockedLookup.mockRejectedValueOnce(new Error('Request failed: 404'));
    render(<RemoteLoginPage />);

    await screen.findByText('Enter pairing code');

    for (const [index, digit] of ['K', '7', 'R', '2', 'P'].entries()) {
      await user.type(screen.getByLabelText(`Code digit ${index + 1}`), digit);
    }

    expect(await screen.findByText(/request failed: 404/i)).toBeInTheDocument();
    expect(screen.getByText('Enter pairing code')).toBeInTheDocument();
  });

  it('surfaces a failed confirmation', async () => {
    const user = userEvent.setup();
    mockAuth(true);
    mockedConfirm.mockRejectedValueOnce(new Error('Request failed: 400'));
    setSearch('?qr_id=qr_test_1&code=K7R2P&sig=deadbeef');
    render(<RemoteLoginPage />);

    await screen.findByText('Name this device');
    await user.type(screen.getByPlaceholderText(/living room tv/i), 'Kitchen TV');
    await user.click(screen.getByRole('button', { name: /pair device/i }));

    expect(await screen.findByText(/request failed: 400/i)).toBeInTheDocument();
  });
});
