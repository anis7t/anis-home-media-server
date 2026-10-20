import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router';

import AppShell from './app/AppShell';
import { AuthProvider } from './auth/AuthProvider';
import AccountPage from './features/account/AccountPage';
import DevicesPage from './features/devices/DevicesPage';
import DownloadPage from './features/download/DownloadPage';
import LibraryPage from './features/library/LibraryPage';
import ManagePage from './features/manage/ManagePage';
import ManualPage from './features/manual/ManualPage';
import MovieDetailsPage from './features/media-details/MovieDetailsPage';
import PlayerPage from './features/playback/PlayerPage';
import RemoteLoginPage from './features/remote-login/RemoteLoginPage';
import TranscodeDashboardPage from './features/transcodes/TranscodeDashboardPage';
import './index.css';

const container = document.getElementById('root');
if (!container) throw new Error('Root container #root is missing from index.html');

createRoot(container).render(
  <StrictMode>
    <BrowserRouter>
      <AuthProvider>
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
            <Route path="/account" element={<AccountPage />} />
            <Route path="/remotelogin" element={<RemoteLoginPage />} />
            <Route path="/manage" element={<ManagePage />} />
            <Route path="/library-manage" element={<ManagePage />} />
            <Route path="/transcodes" element={<TranscodeDashboardPage />} />
            <Route path="/admin/transcodes" element={<TranscodeDashboardPage />} />
            <Route path="/devices" element={<DevicesPage />} />
            <Route path="/clients" element={<DevicesPage />} />
            <Route path="/download" element={<DownloadPage />} />
            <Route path="/app" element={<DownloadPage />} />
            <Route path="/android" element={<DownloadPage />} />
            <Route path="/manual" element={<ManualPage />} />
            <Route path="/help" element={<ManualPage />} />
            <Route path="/how-to-use" element={<ManualPage />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </AppShell>
      </AuthProvider>
    </BrowserRouter>
  </StrictMode>,
);