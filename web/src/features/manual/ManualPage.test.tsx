import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { BrowserRouter } from 'react-router';
import { describe, expect, it, vi } from 'vitest';
import { ManualPage } from './ManualPage';

describe('ManualPage', () => {
  it('renders documentation hero, quick-jump nav, and major manual sections', () => {
    render(
      <BrowserRouter>
        <ManualPage />
      </BrowserRouter>
    );

    // Hero title
    expect(
      screen.getByRole('heading', { level: 1, name: /Controls, Streaming & Architecture Guide/i })
    ).toBeInTheDocument();

    // Section headings
    expect(screen.getByRole('heading', { level: 2, name: /Desktop Keyboard Shortcuts/i })).toBeInTheDocument();
    expect(screen.getByRole('heading', { level: 2, name: /Touch Gestures/i })).toBeInTheDocument();
    expect(screen.getByRole('heading', { level: 2, name: /10-Foot TV Remote Navigation/i })).toBeInTheDocument();
    expect(screen.getByRole('heading', { level: 2, name: /Zero-Password Device Pairing/i })).toBeInTheDocument();

    // The retired add-device / pairing-token flow must not be documented
    expect(screen.queryByText(/Generate Pairing Token/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/1-Year Token/i)).not.toBeInTheDocument();

    expect(screen.getByRole('heading', { level: 2, name: /Subtitles & Dual-Axis Customization/i })).toBeInTheDocument();
    expect(screen.getByRole('heading', { level: 2, name: /Second-Screen Playback/i })).toBeInTheDocument();
    expect(screen.getByRole('heading', { level: 2, name: /Dual-GPU Streaming & Storage Topology/i })).toBeInTheDocument();
    expect(screen.getByRole('heading', { level: 2, name: /Admin Security & Retention Policies/i })).toBeInTheDocument();

    // Key shortcut rows
    expect(screen.getByText('Space / K')).toBeInTheDocument();
    expect(screen.getByText('J / L')).toBeInTheDocument();

    // TV Remote concepts
    expect(screen.getByText(/Zone 1: Timeline Scrubber/i)).toBeInTheDocument();
    expect(screen.getByText(/Zone 2: Transport Rail/i)).toBeInTheDocument();
    expect(screen.getByText(/The TV Remote Back Button Protocol/i)).toBeInTheDocument();
  });

  it('scrolls to section on quick-jump pill click', async () => {
    const user = userEvent.setup();
    const scrollIntoViewMock = vi.fn();
    window.HTMLElement.prototype.scrollIntoView = scrollIntoViewMock;

    render(
      <BrowserRouter>
        <ManualPage />
      </BrowserRouter>
    );

    const tvRemotePill = screen.getByRole('button', { name: /10-Foot TV Remote/i });
    await user.click(tvRemotePill);

    expect(scrollIntoViewMock).toHaveBeenCalledWith({ behavior: 'smooth', block: 'start' });
  });
});
