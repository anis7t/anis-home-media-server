import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ChangeAdminPinModal } from './ChangeAdminPinModal';
import * as manageApi from '../../../lib/api/manage';

vi.mock('../../../lib/api/manage', async () => {
  const actual = await vi.importActual<typeof manageApi>('../../../lib/api/manage');
  return {
    ...actual,
    changeAdminPin: vi.fn(),
  };
});

describe('ChangeAdminPinModal', () => {
  const onClose = vi.fn();
  const onSuccess = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
    sessionStorage.clear();
  });

  it('renders nothing when isOpen is false', () => {
    const { container } = render(
      <ChangeAdminPinModal
        isOpen={false}
        onClose={onClose}
        onSuccess={onSuccess}
      />
    );
    expect(container.firstChild).toBeNull();
  });

  it('renders form inputs and buttons when open', () => {
    render(
      <ChangeAdminPinModal
        isOpen={true}
        defaultCurrentPin="791654"
        onClose={onClose}
        onSuccess={onSuccess}
      />
    );

    expect(screen.getByRole('dialog')).toBeInTheDocument();
    expect(screen.getByText('Rotate Admin PIN')).toBeInTheDocument();
    expect(screen.getByLabelText(/Current PIN/i)).toHaveValue('791654');
    expect(screen.getByLabelText(/^New PIN/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/Confirm New PIN/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Rotate PIN/i })).toBeDisabled();
  });

  it('validates short PINs (< 4 digits)', async () => {
    const user = userEvent.setup();
    render(
      <ChangeAdminPinModal
        isOpen={true}
        defaultCurrentPin="791654"
        onClose={onClose}
        onSuccess={onSuccess}
      />
    );

    await user.type(screen.getByLabelText(/^New PIN/i), '123');
    await user.type(screen.getByLabelText(/Confirm New PIN/i), '123');

    const submitBtn = screen.getByRole('button', { name: /Rotate PIN/i });
    expect(submitBtn).not.toBeDisabled();
    await user.click(submitBtn);

    expect(screen.getByText(/New PIN must be at least 4 digits/i)).toBeInTheDocument();
    expect(manageApi.changeAdminPin).not.toHaveBeenCalled();
  });

  it('validates non-numeric characters', async () => {
    const user = userEvent.setup();
    render(
      <ChangeAdminPinModal
        isOpen={true}
        defaultCurrentPin="791654"
        onClose={onClose}
        onSuccess={onSuccess}
      />
    );

    await user.type(screen.getByLabelText(/^New PIN/i), 'abcd');
    await user.type(screen.getByLabelText(/Confirm New PIN/i), 'abcd');

    await user.click(screen.getByRole('button', { name: /Rotate PIN/i }));

    expect(screen.getByText(/numeric digits only/i)).toBeInTheDocument();
    expect(manageApi.changeAdminPin).not.toHaveBeenCalled();
  });

  it('validates mismatched new PIN and confirmation', async () => {
    const user = userEvent.setup();
    render(
      <ChangeAdminPinModal
        isOpen={true}
        defaultCurrentPin="791654"
        onClose={onClose}
        onSuccess={onSuccess}
      />
    );

    await user.type(screen.getByLabelText(/^New PIN/i), '123456');
    await user.type(screen.getByLabelText(/Confirm New PIN/i), '654321');

    await user.click(screen.getByRole('button', { name: /Rotate PIN/i }));

    expect(screen.getByText(/do not match/i)).toBeInTheDocument();
    expect(manageApi.changeAdminPin).not.toHaveBeenCalled();
  });

  it('submits valid rotation and updates session storage on success', async () => {
    const user = userEvent.setup();
    vi.mocked(manageApi.changeAdminPin).mockResolvedValueOnce({ success: true });

    render(
      <ChangeAdminPinModal
        isOpen={true}
        defaultCurrentPin="791654"
        onClose={onClose}
        onSuccess={onSuccess}
      />
    );

    await user.type(screen.getByLabelText(/^New PIN/i), '987654');
    await user.type(screen.getByLabelText(/Confirm New PIN/i), '987654');

    await user.click(screen.getByRole('button', { name: /Rotate PIN/i }));

    await waitFor(() => {
      expect(manageApi.changeAdminPin).toHaveBeenCalledWith({
        currentPin: '791654',
        newPin: '987654',
      });
      expect(sessionStorage.getItem('ms_admin_pin')).toBe('987654');
      expect(onSuccess).toHaveBeenCalledWith('987654');
      expect(onClose).toHaveBeenCalled();
    });
  });

  it('displays API error when update fails', async () => {
    const user = userEvent.setup();
    vi.mocked(manageApi.changeAdminPin).mockResolvedValueOnce({
      success: false,
      error: 'Administrator privileges required to change PIN.',
    });

    render(
      <ChangeAdminPinModal
        isOpen={true}
        defaultCurrentPin="000000"
        onClose={onClose}
        onSuccess={onSuccess}
      />
    );

    await user.type(screen.getByLabelText(/^New PIN/i), '987654');
    await user.type(screen.getByLabelText(/Confirm New PIN/i), '987654');

    await user.click(screen.getByRole('button', { name: /Rotate PIN/i }));

    await waitFor(() => {
      expect(screen.getByText(/Administrator privileges required to change PIN/i)).toBeInTheDocument();
      expect(onSuccess).not.toHaveBeenCalled();
      expect(onClose).not.toHaveBeenCalled();
    });
  });

  it('calls onClose when Cancel or Close cross is clicked', async () => {
    const user = userEvent.setup();
    render(
      <ChangeAdminPinModal
        isOpen={true}
        onClose={onClose}
        onSuccess={onSuccess}
      />
    );

    await user.click(screen.getByRole('button', { name: /Cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(1);

    await user.click(screen.getByRole('button', { name: /Close dialog/i }));
    expect(onClose).toHaveBeenCalledTimes(2);
  });
});
