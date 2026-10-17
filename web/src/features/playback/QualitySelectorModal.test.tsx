import { render, screen, fireEvent } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { QualitySelectorModal } from './QualitySelectorModal';
import type { QualityOption } from '../../lib/api/types';

const MOCK_LADDER: QualityOption[] = [
  {
    label: 'Direct Play (Source)',
    quality: 'source',
    height: 1080,
    width: 1920,
    bitrate: 4500000,
    is_direct: true,
    is_ready: true,
    hls_url: null,
  },
  {
    label: '720p',
    quality: '720p',
    height: 720,
    width: 1280,
    bitrate: 2200000,
    is_direct: false,
    is_ready: true,
    hls_url: '/hls/test.mkv/720p/playlist.m3u8',
  },
  {
    label: '480p',
    quality: '480p',
    height: 480,
    width: 854,
    bitrate: 1200000,
    is_direct: false,
    is_ready: false,
    hls_url: '/hls/test.mkv/480p/playlist.m3u8',
  },
];

describe('QualitySelectorModal', () => {
  it('does not render when isOpen is false', () => {
    const { container } = render(
      <QualitySelectorModal
        isOpen={false}
        onClose={vi.fn()}
        qualityLadder={MOCK_LADDER}
        selectedQuality="auto"
        onSelectQuality={vi.fn()}
      />,
    );
    expect(container.firstChild).toBeNull();
  });

  it('renders Auto and all ladder options when open', () => {
    render(
      <QualitySelectorModal
        isOpen={true}
        onClose={vi.fn()}
        qualityLadder={MOCK_LADDER}
        selectedQuality="auto"
        onSelectQuality={vi.fn()}
      />,
    );

    expect(screen.getByTestId('quality-selector-modal')).toBeInTheDocument();
    expect(screen.getByText('Playback Quality')).toBeInTheDocument();
    expect(screen.getByText('Auto (Adaptive)')).toBeInTheDocument();
    expect(screen.getByText('Direct Play (Source)')).toBeInTheDocument();
    expect(screen.getByText('720p')).toBeInTheDocument();
    expect(screen.getByText('480p')).toBeInTheDocument();

    // Check badges
    expect(screen.getByText('Recommended')).toBeInTheDocument();
    expect(screen.getByText('Cached')).toBeInTheDocument();
    expect(screen.getByText('Transcode On-Demand')).toBeInTheDocument();
  });

  it('calls onSelectQuality and onClose when an option is clicked', () => {
    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(
      <QualitySelectorModal
        isOpen={true}
        onClose={onClose}
        qualityLadder={MOCK_LADDER}
        selectedQuality="auto"
        onSelectQuality={onSelect}
      />,
    );

    fireEvent.click(screen.getByTestId('quality-opt-720p'));
    expect(onSelect).toHaveBeenCalledWith('720p', MOCK_LADDER[1]);
    expect(onClose).toHaveBeenCalled();
  });

  it('calls onClose when close button is clicked', () => {
    const onClose = vi.fn();
    render(
      <QualitySelectorModal
        isOpen={true}
        onClose={onClose}
        qualityLadder={MOCK_LADDER}
        selectedQuality="auto"
        onSelectQuality={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByLabelText('Close quality selector'));
    expect(onClose).toHaveBeenCalled();
  });

  it('calls onClose on Escape key press', () => {
    const onClose = vi.fn();
    render(
      <QualitySelectorModal
        isOpen={true}
        onClose={onClose}
        qualityLadder={MOCK_LADDER}
        selectedQuality="720p"
        onSelectQuality={vi.fn()}
      />,
    );

    fireEvent.keyDown(window, { key: 'Escape' });
    expect(onClose).toHaveBeenCalled();
  });
});
