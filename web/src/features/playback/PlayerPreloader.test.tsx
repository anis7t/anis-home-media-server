import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { PlayerPreloader } from './PlayerPreloader';

describe('PlayerPreloader', () => {
  it('renders with visible state and default message', () => {
    render(<PlayerPreloader visible={true} />);
    const preloader = document.getElementById('playerPreloader');
    expect(preloader).not.toBeNull();
    expect(preloader).not.toHaveAttribute('hidden');
    expect(preloader?.style.display).toBe('flex');
    expect(screen.getByText('Loading Media')).toBeInTheDocument();
    expect(screen.getByText('Initializing player & streams...')).toBeInTheDocument();
  });

  it('renders custom message when provided', () => {
    render(<PlayerPreloader visible={true} message="Preparing Dual-GPU HLS streams..." />);
    expect(screen.getByText('Preparing Dual-GPU HLS streams...')).toBeInTheDocument();
  });

  it('is hidden when visible is false', () => {
    render(<PlayerPreloader visible={false} />);
    const preloader = document.getElementById('playerPreloader');
    expect(preloader).toHaveAttribute('hidden');
    expect(preloader?.style.display).toBe('none');
  });

  it('calls onDismiss when clicked', () => {
    const onDismiss = vi.fn();
    render(<PlayerPreloader visible={true} onDismiss={onDismiss} />);
    const preloader = document.getElementById('playerPreloader');
    expect(preloader).not.toBeNull();
    fireEvent.click(preloader!);
    expect(onDismiss).toHaveBeenCalledTimes(1);
  });
});
