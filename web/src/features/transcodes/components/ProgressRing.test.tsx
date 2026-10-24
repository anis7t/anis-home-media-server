import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { ProgressRing } from './ProgressRing';

describe('ProgressRing Component', () => {
  it('renders a progressbar with correct accessibility attributes', () => {
    render(<ProgressRing value={45.2} />);
    const bar = screen.getByRole('progressbar');
    expect(bar).toBeInTheDocument();
    expect(bar).toHaveAttribute('aria-valuenow', '45.2');
    expect(bar).toHaveAttribute('aria-valuemin', '0');
    expect(bar).toHaveAttribute('aria-valuemax', '100');
    expect(bar).toHaveAttribute('aria-label', 'Transcode progress: 45.2%');
    expect(screen.getByText('45.2%')).toBeInTheDocument();
  });

  it('renders speed label when provided', () => {
    render(<ProgressRing value={75} speedLabel="2.4x" />);
    expect(screen.getByText('2.4x')).toBeInTheDocument();
  });

  it('renders queued status correctly', () => {
    render(<ProgressRing value={0} status="queued" />);
    const bar = screen.getByRole('progressbar');
    expect(bar).toHaveAttribute('aria-label', 'Queued transcode');
    expect(screen.getByText(/queue/i)).toBeInTheDocument();
  });

  it('clamps values between 0 and 100', () => {
    render(<ProgressRing value={120} />);
    const bar = screen.getByRole('progressbar');
    expect(bar).toHaveAttribute('aria-valuenow', '100');
    expect(screen.getByText('100.0%')).toBeInTheDocument();
  });
});
