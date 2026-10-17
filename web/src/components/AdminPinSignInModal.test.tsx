import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AdminPinSignInModal from './AdminPinSignInModal';
import * as accountApi from '../lib/api/account';

vi.mock('../lib/api/account', () => ({
  loginWithPin: vi.fn(),
}));

describe('AdminPinSignInModal', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders nothing when isOpen is false', () => {
    const { container } = render(
      <AdminPinSignInModal isOpen={false} onClose={vi.fn()} />
    );
    expect(container).toBeEmptyDOMElement();
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  });

  it('renders modal dialog and elements when isOpen is true', () => {
    render(
      <AdminPinSignInModal isOpen={true} onClose={vi.fn()} oauthConfigured={true} />
    );

    expect(screen.getByRole('dialog')).toBeInTheDocument();
    expect(
      screen.getByRole('heading', { level: 2, name: /Admin PIN Sign-In/i })
    ).toBeInTheDocument();
    expect(screen.getByLabelText(/Enter Administrator PIN/i)).toBeInTheDocument();
    expect(
      screen.getByRole('button', { name: /Sign In as Admin/i })
    ).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Cancel/i })).toBeInTheDocument();
  });

  it('displays OAuth setup guide warning when oauthConfigured is false', async () => {
    const user = userEvent.setup();
    render(
      <AdminPinSignInModal isOpen={true} onClose={vi.fn()} oauthConfigured={false} />
    );

    expect(screen.getByText(/Google Sign-In Not Configured/i)).toBeInTheDocument();
    expect(screen.getByText(/GOOGLE_CLIENT_ID=/i)).toBeInTheDocument();

    // Toggle guide off and on
    const toggleBtn = screen.getByRole('button', { name: /Hide guide/i });
    await user.click(toggleBtn);
    expect(screen.queryByText(/GOOGLE_CLIENT_ID=/i)).not.toBeInTheDocument();
  });

  it('submits valid PIN and invokes onSuccess and onClose on success', async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();
    const onSuccess = vi.fn();

    vi.mocked(accountApi.loginWithPin).mockResolvedValueOnce({
      success: true,
      user: {
        id: 'admin_pin',
        email: 'admin@local',
        name: 'Administrator',
        role: 'admin',
        is_admin: true,
        created_at: '',
      },
    });

    render(
      <AdminPinSignInModal
        isOpen={true}
        onClose={onClose}
        onSuccess={onSuccess}
        oauthConfigured={false}
      />
    );

    const input = screen.getByLabelText(/Enter Administrator PIN/i);
    await user.type(input, '2468');

    const submitBtn = screen.getByRole('button', { name: /Sign In as Admin/i });
    await user.click(submitBtn);

    await waitFor(() => {
      expect(accountApi.loginWithPin).toHaveBeenCalledWith('2468');
      expect(onSuccess).toHaveBeenCalledTimes(1);
      expect(onClose).toHaveBeenCalledTimes(1);
    });
  });

  it('displays error message when loginWithPin fails', async () => {
    const user = userEvent.setup();
    vi.mocked(accountApi.loginWithPin).mockRejectedValueOnce(
      new Error('Invalid Admin PIN. Please check and try again.')
    );

    render(
      <AdminPinSignInModal
        isOpen={true}
        onClose={vi.fn()}
        oauthConfigured={true}
      />
    );

    const input = screen.getByLabelText(/Enter Administrator PIN/i);
    await user.type(input, 'wrong');

    const submitBtn = screen.getByRole('button', { name: /Sign In as Admin/i });
    await user.click(submitBtn);

    await waitFor(() => {
      expect(
        screen.getByText(/Invalid Admin PIN\. Please check and try again\./i)
      ).toBeInTheDocument();
    });
  });

  it('calls onClose when clicking Cancel button or pressing Escape', async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();

    render(
      <AdminPinSignInModal isOpen={true} onClose={onClose} />
    );

    const cancelBtn = screen.getByRole('button', { name: /Cancel/i });
    await user.click(cancelBtn);
    expect(onClose).toHaveBeenCalledTimes(1);

    await user.keyboard('{Escape}');
    expect(onClose).toHaveBeenCalledTimes(2);
  });
});
