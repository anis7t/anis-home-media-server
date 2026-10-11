import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router';

import AppShell from './app/AppShell';
import LibraryPage from './features/library/LibraryPage';
import MovieDetailsPage from './features/media-details/MovieDetailsPage';
import PlayerPage from './features/playback/PlayerPage';
import './index.css';

const container = document.getElementById('root');
if (!container) throw new Error('Root container #root is missing from index.html');

createRoot(container).render(
  <StrictMode>
    <BrowserRouter>
      <AppShell>
        <Routes>
          <Route path="/" element={<LibraryPage />} />
          {/*
            Splat routes, not `:filename`. Media filenames are relative paths
            ("2001 A Space Odyssey (1968) [BluRay]/2001...mp4") and contain
            slashes, so a single-segment param would only ever capture the first
            segment. The server solves the same problem with `<path:filename>`.
          */}
          <Route path="/movie/*" element={<MovieDetailsPage />} />
          <Route path="/watch/*" element={<PlayerPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </AppShell>
    </BrowserRouter>
  </StrictMode>,
);