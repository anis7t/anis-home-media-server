import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { AuthProvider } from '../auth/AuthProvider';
import { AppShell } from './AppShell';

const { isPhoneMock } = vi.hoisted(() => ({
  isPhoneMock: vi.fn(() => false),
}));

vi.mock('../lib/signInPlatform', () => ({
  useIsPhoneBrowser: () => isPhoneMock(),
}));

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: 'OK',
    json: async () => body,
  } as Response;
}

interface MockApiOptions {
  readonly authenticated: boolean;
  readonly oauthConfigured?: boolean;
}

let fetchMock: ReturnType<typeof vi.fn>;

function mockApi({ authenticated, oauthConfigured = true }: MockApiOptions) {
  fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
    const url = String(input);

    if (url === '/api/auth/me') {
      return jsonResponse(
        authenticated
          ? {
              authenticated: true,
              email: 'owner@example.com',
              name: 'Anis',
              role: 'admin',
              oauth_configured: oauthConfigured,
            }
          : {
              authenticated: false,
              oauth_configured: oauthConfigured,
            },
      );
    }

    if (url === '/api/transcodes') {
      return jsonResponse({ transcodes: [] });
    }

    return jsonResponse({});
  });
}

function renderShell() {
  return render(
    <MemoryRouter initialEntries={['/?intro=off']}>
      <AuthProvider>
        <AppShell>
          <div>content</div>
        </AppShell>
      </AuthProvider>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  isPhoneMock.mockReturnValue(false);
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('AppShell sign-in header', () => {
  it('opens a chooser instead of starting Google sign-in immediately', async () => {
    const user = userEvent.setup();
    mockApi({ authenticated: false });
    renderShell();

    const trigger = await screen.findByRole('button', { name: 'Sign in' });
    expect(trigger).toHaveAttribute('aria-haspopup', 'menu');
    expect(trigger).toHaveAttribute('aria-expanded', 'false');

    await user.click(trigger);

    expect(trigger).toHaveAttribute('aria-expanded', 'true');
    expect(await screen.findByRole('menu')).toBeInTheDocument();
    expect(
      screen.getByRole('menuitem', { name: /continue with google/i }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole('menuitem', { name: /sign in with qr code/i }),
    ).toBeInTheDocument();
  });

  it('keeps a direct Google button on a phone browser', async () => {
    isPhoneMock.mockReturnValue(true);
    mockApi({ authenticated: false });
    renderShell();

    const trigger = await screen.findByRole('button', { name: 'Sign in' });
    expect(trigger).not.toHaveAttribute('aria-haspopup');
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    expect(screen.queryByText(/sign in with qr code/i)).not.toBeInTheDocument();
  });

  it('offers the Admin PIN when OAuth is not configured', async () => {
    const user = userEvent.setup();
    mockApi({ authenticated: false, oauthConfigured: false });
    renderShell();

    await user.click(await screen.findByRole('button', { name: 'Sign in' }));

    expect(
      await screen.findByRole('menuitem', { name: /sign in with admin pin/i }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole('menuitem', { name: /continue with google/i }),
    ).not.toBeInTheDocument();
  });

  it('leaves the signed-in avatar menu unchanged', async () => {
    mockApi({ authenticated: true });
    renderShell();

    expect(
      await screen.findByRole('button', { name: 'Open account menu' }),
    ).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Sign in' })).not.toBeInTheDocument();
  });
});
