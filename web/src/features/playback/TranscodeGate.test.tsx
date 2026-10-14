import { render, screen, fireEvent } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { TranscodeGate } from './TranscodeGate';

describe('TranscodeGate component', () => {
  it('renders hardware transcode badge and title', () => {
    render(
      <TranscodeGate
        filename="Movies/Inception (2010).mkv"
        transcode={{
          status: 'building',
          percent: 45,
          speed: 2.8,
          remaining: 120,
          duration: 9000,
          encoded: 4050,
          bytes: 12000000,
        }}
      />
    );

    expect(screen.getByRole('region', { name: /transcode progress gate/i })).toBeInTheDocument();
    expect(screen.getByText(/Dual AMD GPU Transcoder Active/i)).toBeInTheDocument();
    expect(screen.getByText(/Building a transcode for 'Inception \(2010\)'/i)).toBeInTheDocument();
  });

  it('renders progress percentage, speed, and ETA', () => {
    render(
      <TranscodeGate
        filename="Test.mkv"
        transcode={{
          status: 'building',
          percent: 75.4,
          speed: 3.5,
          remaining: 85,
          duration: 3600,
          encoded: 2700,
          bytes: 50000000,
        }}
      />
    );

    expect(screen.getByText(/75%/i)).toBeInTheDocument();
    expect(screen.getByText(/3.5×/i)).toBeInTheDocument();
    expect(screen.getByText(/1m 25s/i)).toBeInTheDocument();

    const fill = document.getElementById('transcodeGateFill');
    expect(fill).toHaveStyle({ width: '75.4%' });
  });

  it('calls onRefresh when check status button is clicked', () => {
    const handleRefresh = vi.fn();
    render(
      <TranscodeGate
        filename="Test.mkv"
        transcode={null}
        onRefresh={handleRefresh}
      />
    );

    const btn = screen.getByRole('button', { name: /check status/i });
    fireEvent.click(btn);
    expect(handleRefresh).toHaveBeenCalledTimes(1);
  });
});
