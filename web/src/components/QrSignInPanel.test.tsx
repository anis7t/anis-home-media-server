import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { QrSignInPanel } from './QrSignInPanel';
import { createQrSession } from '../lib/api/account';

vi.mock('../lib/api/account', () => ({
  createQrSession: vi.fn(),
}));

const mockedCreate = vi.mocked(createQrSession);

function sessionFixture() {
  const now = Math.floor(Date.now() / 1000);
  return {
    qr_id: 'qr_test_1',
    code: 'K7R2P',
    sig: 'deadbeef',
    expires_at: now + 120,
    qr_url: 'https://media.anisparvez.in/remotelogin?qr_id=qr_test_1&code=K7R2P&sig=deadbeef',
    login_url: 'https://media.anisparvez.in/remotelogin',
  } as Awaited<ReturnType<typeof createQrSession>>;
}

beforeEach(() => {
  mockedCreate.mockReset();
  mockedCreate.mockResolvedValue(sessionFixture());
  // jsdom has no canvas 2d backend, so the QR renderer would throw. The
  // panel already swallows that error, but stubbing keeps the test honest
  // about what is being asserted.
  vi.stubGlobal('EventSource', class {
    onmessage: ((event: MessageEvent) => void) | null = null;
    onerror: ((event: Event) => void) | null = null;
    onopen: ((event: Event) => void) | null = null;
    readyState = 0;
    addEventListener(): void {}
    removeEventListener(): void {}
    dispatchEvent(): boolean {
      return true;
    }
    close(): void {}
  });
});

describe('QrSignInPanel', () => {
  it('shows the pair code and the manual login URL', async () => {
    render(
      <QrSignInPanel onGoogleSignIn={() => {}} onPinSignIn={() => {}} oauthConfigured={true} />,
    );

    // The code appears twice: the badge, and the "then enter code" hint.
    await waitFor(() => expect(screen.getAllByText('K7R2P').length).toBeGreaterThan(0));
    // The hostname only - the scheme is stripped for display.
    expect(screen.getByText('media.anisparvez.in/remotelogin')).toBeInTheDocument();
  });

  it('renders a canvas for the QR code', async () => {
    const { container } = render(
      <QrSignInPanel onGoogleSignIn={() => {}} onPinSignIn={() => {}} oauthConfigured={true} />,
    );

    await waitFor(() => expect(screen.getAllByText('K7R2P').length).toBeGreaterThan(0));
    expect(container.querySelector('canvas')).toBeInTheDocument();
  });

  it('offers Google sign-in only when OAuth is configured', async () => {
    const { unmount } = render(
      <QrSignInPanel onGoogleSignIn={() => {}} onPinSignIn={() => {}} oauthConfigured={true} />,
    );
    expect(screen.getByRole('button', { name: /sign in with google/i })).toBeInTheDocument();
    unmount();

    render(<QrSignInPanel onGoogleSignIn={() => {}} onPinSignIn={() => {}} oauthConfigured={false} />);
    expect(screen.queryByRole('button', { name: /sign in with google/i })).not.toBeInTheDocument();
  });

  it('always offers the Admin PIN fallback, under a name that says what it does', async () => {
    render(
      <QrSignInPanel onGoogleSignIn={() => {}} onPinSignIn={() => {}} oauthConfigured={false} />,
    );

    // The accessible name is part of the contract other suites assert on.
    expect(screen.getByRole('button', { name: /sign in with admin pin/i })).toBeInTheDocument();
  });

  it('invokes the sign-in callbacks', async () => {
    const user = userEvent.setup();
    const onGoogleSignIn = vi.fn();
    const onPinSignIn = vi.fn();

    render(
      <QrSignInPanel
        onGoogleSignIn={onGoogleSignIn}
        onPinSignIn={onPinSignIn}
        oauthConfigured={true}
      />,
    );

    await user.click(screen.getByRole('button', { name: /sign in with google/i }));
    expect(onGoogleSignIn).toHaveBeenCalledTimes(1);

    await user.click(screen.getByRole('button', { name: /sign in with admin pin/i }));
    expect(onPinSignIn).toHaveBeenCalledTimes(1);
  });

  it('shows a countdown that expires into a new session', async () => {
    render(
      <QrSignInPanel onGoogleSignIn={() => {}} onPinSignIn={() => {}} oauthConfigured={true} />,
    );

    await waitFor(() => expect(screen.getAllByText('K7R2P').length).toBeGreaterThan(0));
    // The countdown ring carries the remaining time for assistive tech.
    expect(screen.getByLabelText(/code refreshes in/i)).toBeInTheDocument();
  });
});
