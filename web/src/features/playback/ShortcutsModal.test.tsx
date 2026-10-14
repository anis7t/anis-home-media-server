import { render, screen, fireEvent } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { ShortcutsModal } from './ShortcutsModal';

describe('ShortcutsModal', () => {
  it('does not render when isOpen is false', () => {
    render(<ShortcutsModal isOpen={false} onClose={vi.fn()} />);
    expect(screen.queryByTestId('shortcuts-modal')).toBeNull();
  });

  it('renders all shortcut categories and handles close', () => {
    const onClose = vi.fn();
    render(<ShortcutsModal isOpen={true} onClose={onClose} />);

    const modal = screen.getByTestId('shortcuts-modal');
    expect(modal).toBeDefined();

    expect(screen.getByText('Shortcuts & Gestures')).toBeDefined();
    expect(screen.getByText('Playback & Navigation')).toBeDefined();
    expect(screen.getByText('Audio & Screen')).toBeDefined();
    expect(screen.getByText('Subtitles & Speed')).toBeDefined();
    expect(screen.getByText('Touch & Mobile Gestures')).toBeDefined();

    // Check specific shortcut labels
    expect(screen.getByText('Play / Pause')).toBeDefined();
    expect(screen.getByText('Stats for Nerds')).toBeDefined();
    expect(screen.getByText('Aspect Ratio')).toBeDefined();
    expect(screen.getByText('Rotate Screen')).toBeDefined();

    // Close button
    const closeBtn = document.getElementById('closeShortcutsModal');
    expect(closeBtn).toBeDefined();
    if (closeBtn) {
      fireEvent.click(closeBtn);
      expect(onClose).toHaveBeenCalledOnce();
    }
  });
});
