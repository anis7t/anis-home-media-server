import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { describe, expect, it, vi } from 'vitest';

import { SignInMenu, type SignInMenuProps } from './SignInMenu';

function renderMenu(overrides: Partial<SignInMenuProps> = {}) {
  const onGoogleSignIn = vi.fn();
  const onPinSignIn = vi.fn();

  render(
    <MemoryRouter>
      <SignInMenu
        oauthConfigured={true}
        onGoogleSignIn={onGoogleSignIn}
        onPinSignIn={onPinSignIn}
        {...overrides}
      />
    </MemoryRouter>,
  );

  return { onGoogleSignIn, onPinSignIn };
}

describe('SignInMenu', () => {
  it('opens a menu with Google and QR options instead of signing in immediately', async () => {
    const user = userEvent.setup();
    renderMenu();

    const trigger = screen.getByRole('button', { name: 'Sign in' });
    expect(trigger).toHaveAttribute('aria-haspopup', 'menu');
    expect(trigger).toHaveAttribute('aria-expanded', 'false');
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();

    await user.click(trigger);

    expect(trigger).toHaveAttribute('aria-expanded', 'true');
    expect(screen.getByRole('menu')).toBeInTheDocument();
    expect(
      screen.getByRole('menuitem', { name: /continue with google/i }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole('menuitem', { name: /sign in with qr code/i }),
    ).toBeInTheDocument();
  });

  it('invokes the existing Google flow and closes the menu', async () => {
    const user = userEvent.setup();
    const { onGoogleSignIn } = renderMenu();

    await user.click(screen.getByRole('button', { name: 'Sign in' }));
    await user.click(screen.getByRole('menuitem', { name: /continue with google/i }));

    expect(onGoogleSignIn).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
  });

  it('links the QR option to /account and closes the menu', async () => {
    const user = userEvent.setup();
    renderMenu();

    await user.click(screen.getByRole('button', { name: 'Sign in' }));
    const qrItem = screen.getByRole('menuitem', { name: /sign in with qr code/i });
    expect(qrItem).toHaveAttribute('href', '/account');

    await user.click(qrItem);
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
  });

  it('offers the Admin PIN instead of Google when OAuth is unconfigured', async () => {
    const user = userEvent.setup();
    const { onPinSignIn } = renderMenu({ oauthConfigured: false });

    await user.click(screen.getByRole('button', { name: 'Sign in' }));

    expect(screen.queryByRole('menuitem', { name: /continue with google/i })).not.toBeInTheDocument();
    const pinItem = screen.getByRole('menuitem', { name: /sign in with admin pin/i });
    expect(pinItem).toBeInTheDocument();
    expect(
      screen.getByRole('menuitem', { name: /sign in with qr code/i }),
    ).toBeInTheDocument();

    await user.click(pinItem);
    expect(onPinSignIn).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
  });

  it('closes on Escape and returns focus to the trigger', async () => {
    const user = userEvent.setup();
    renderMenu();

    const trigger = screen.getByRole('button', { name: 'Sign in' });
    await user.click(trigger);
    await user.keyboard('{Escape}');

    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });

  it('closes on an outside click', async () => {
    const user = userEvent.setup();
    renderMenu();

    await user.click(screen.getByRole('button', { name: 'Sign in' }));
    expect(screen.getByRole('menu')).toBeInTheDocument();

    await user.click(document.body);
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
  });

  it('moves focus through the menu with arrow keys', async () => {
    const user = userEvent.setup();
    renderMenu();

    await user.click(screen.getByRole('button', { name: 'Sign in' }));
    const googleItem = screen.getByRole('menuitem', { name: /continue with google/i });
    const qrItem = screen.getByRole('menuitem', { name: /sign in with qr code/i });

    expect(googleItem).toHaveFocus();
    await user.keyboard('{ArrowDown}');
    expect(qrItem).toHaveFocus();
    await user.keyboard('{ArrowUp}');
    expect(googleItem).toHaveFocus();
  });
});
