import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { BrowserRouter } from 'react-router';
import { describe, expect, it, vi } from 'vitest';
import DownloadPage from './DownloadPage';

describe('DownloadPage', () => {
  it('renders hero title, version badge, and mobile/tv sections', () => {
    render(
      <BrowserRouter>
        <DownloadPage />
      </BrowserRouter>
    );

    // Hero title
    expect(
      screen.getByRole('heading', { level: 1, name: /Get the Media Server App/i })
    ).toBeInTheDocument();

    // Section headings
    expect(
      screen.getByRole('heading', { level: 2, name: /Android Phones & Tablets/i })
    ).toBeInTheDocument();
    expect(
      screen.getByRole('heading', { level: 2, name: /Amazon Fire TV & Android TV/i })
    ).toBeInTheDocument();

    // Version and size badges
    expect(screen.getByText(/v1\.2\.20/i)).toBeInTheDocument();
    expect(screen.getByText(/97\.5 MB/i)).toBeInTheDocument();

    // Download buttons
    const prodDownload = screen.getByRole('link', { name: /Download Production APK/i });
    expect(prodDownload).toBeInTheDocument();
    expect(prodDownload).toHaveAttribute(
      'href',
      '/api/app/download?channel=production'
    );

    const tvDownload = screen.getByRole('link', { name: /Download for TV & Fire TV/i });
    expect(tvDownload).toBeInTheDocument();
    expect(tvDownload).toHaveAttribute(
      'href',
      '/api/app/download?channel=production'
    );

    // Sideloading steps for Fire TV
    expect(screen.getByText(/How to Sideload on Fire TV:/i)).toBeInTheDocument();
    expect(screen.getByText(/Downloader/i)).toBeInTheDocument();

    // Fingerprint verification
    expect(
      screen.getByRole('heading', { level: 3, name: /Cryptographic Verification & Integrity/i })
    ).toBeInTheDocument();
  });

  it('copies SHA-256 fingerprint when clicking copy button', async () => {
    const user = userEvent.setup();
    const writeTextMock = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: writeTextMock },
      configurable: true,
      writable: true,
    });

    render(
      <BrowserRouter>
        <DownloadPage />
      </BrowserRouter>
    );

    const copyBtn = screen.getByRole('button', { name: /Copy Fingerprint/i });
    await user.click(copyBtn);

    expect(writeTextMock).toHaveBeenCalledWith(
      '7bc4e2716e0f753bf4ca7a142b4a20d69cb7057c3717d10bb42ca052eda168f2'
    );
  });
});
