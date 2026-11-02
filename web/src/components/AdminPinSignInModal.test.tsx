import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AdminPinSignInModal from './AdminPinSignInModal';
import * as accountApi from '../lib/api/account';

vi.mock('../lib/api/account', () => ({
  verifyAdminOtp: vi.fn(),
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
      screen.getByRole('heading', { level: 2, name: /Administrator Verification/i })
    ).toBeInTheDocument();
    expect(screen.getByText(/Enter 6-Digit Access Code/i)).toBeInTheDocument();
    const cells = screen.getAllByRole('textbox');
    expect(cells).toHaveLength(6);
    expect(
      screen.getByRole('button', { name: /Verify & Sign In/i })
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

  it('submits valid 6-digit OTP and invokes onSuccess and onClose on success', async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();
    const onSuccess = vi.fn();

    vi.mocked(accountApi.verifyAdminOtp).mockResolvedValueOnce({
      success: true,
      admin: true,
    });

    render(
      <AdminPinSignInModal
        isOpen={true}
        onClose={onClose}
        onSuccess={onSuccess}
        oauthConfigured={false}
      />
    );

    const cells = screen.getAllByRole('textbox');
    fireEvent.paste(cells[0], {
      clipboardData: { getData: () => '123456' },
    });

    await waitFor(() => {
      expect(accountApi.verifyAdminOtp).toHaveBeenCalledWith('123456');
      expect(onSuccess).toHaveBeenCalledTimes(1);
      expect(onClose).toHaveBeenCalledTimes(1);
    });
  });

  it('displays error message when verifyAdminOtp fails', async () => {
    const user = userEvent.setup();
    vi.mocked(accountApi.verifyAdminOtp).mockResolvedValueOnce({
      success: false,
      admin: false,
      error: 'Invalid or expired access code.',
    });

    render(
      <AdminPinSignInModal
        isOpen={true}
        onClose={vi.fn()}
        oauthConfigured={true}
      />
    );

    const cells = screen.getAllByRole('textbox');
    fireEvent.paste(cells[0], {
      clipboardData: { getData: () => '999999' },
    });

    await waitFor(() => {
      expect(
        screen.getByText(/Invalid or expired access code\./i)
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
