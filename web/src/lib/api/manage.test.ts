import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  archiveMovieMedia,
  deleteMovieMedia,
  fetchManageMovies,
  fetchStorageAudit,
  fetchStorageSettings,
  formatBytes,
  purgeOrphanedCaches,
  triggerLibraryScan,
  updateStoragePolicy,
  verifyAdminPin,
} from './manage';

let fetchMock: ReturnType<typeof vi.fn>;

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : 'Error',
    json: async () => body,
  } as Response;
}

beforeEach(() => {
  sessionStorage.clear();
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('formatBytes', () => {
  it('formats zero and negative values as 0 MB', () => {
    expect(formatBytes(0)).toBe('0 MB');
    expect(formatBytes(undefined)).toBe('0 MB');
    expect(formatBytes(-100)).toBe('0 MB');
  });

  it('formats megabytes and gigabytes accurately', () => {
    expect(formatBytes(50 * 1024 * 1024)).toBe('50.0 MB');
    expect(formatBytes(2.5 * 1024 * 1024 * 1024)).toBe('2.50 GB');
  });
});

describe('manage API client', () => {
  it('fetches movies array cleanly', async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({ movies: [{ filename: 'test.mp4', title: 'Test' }] })
    );
    const movies = await fetchManageMovies();
    expect(movies).toHaveLength(1);
    expect(movies[0].title).toBe('Test');
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/movies',
      expect.objectContaining({ method: 'GET' })
    );
  });

  it('fetches storage settings', async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({ retention_policy: 'keep', archive_dir: 'D:/archive', allowed_policies: ['keep'] })
    );
    const settings = await fetchStorageSettings();
    expect(settings.retention_policy).toBe('keep');
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/storage/settings',
      expect.objectContaining({
        method: 'GET',
      })
    );
  });

  it('fetches storage audit with long media probe timeout', async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({ storage: { free_str: '100 GB' }, audit: { total_orphaned_dirs: 0 } })
    );
    const audit = await fetchStorageAudit();
    expect(audit.storage.free_str).toBe('100 GB');
  });

  it('verifies admin access code via POST', async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ success: true, admin: true }));
    const res = await verifyAdminPin('975312');
    expect(res.success).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/admin/otp/verify',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ otp: '975312' }),
      })
    );
  });

  it('updates storage policy', async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ success: true, retention_policy: 'archive' }));
    const res = await updateStoragePolicy('archive');
    expect(res.success).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/storage/settings',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ retention_policy: 'archive' }),
      })
    );
  });

  it('purges orphaned caches via POST', async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ success: true, result: { purged: 3 } }));
    const res = await purgeOrphanedCaches('97531');
    expect(res.result?.purged).toBe(3);
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/storage/purge-orphans',
      expect.objectContaining({ method: 'POST' })
    );
  });

  it('triggers library scan via POST', async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ success: true }));
    const res = await triggerLibraryScan('97531');
    expect(res.success).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/scan',
      expect.objectContaining({ method: 'POST' })
    );
  });

  it('archives movie media via POST', async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ success: true }));
    const res = await archiveMovieMedia('Matrix.1999.mkv', '97531');
    expect(res.success).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/storage/archive/Matrix.1999.mkv',
      expect.objectContaining({ method: 'POST' })
    );
  });

  it('deletes movie media via DELETE method', async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ success: true, message: 'Purged' }));
    const res = await deleteMovieMedia('Matrix.1999.mkv', '97531');
    expect(res.success).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/media/Matrix.1999.mkv',
      expect.objectContaining({ method: 'DELETE' })
    );
  });
});
