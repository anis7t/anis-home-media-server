import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  fetchTranscodeDashboard,
  cancelTranscodeJob,
  enqueueTranscodeJob,
} from './transcodes';

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : 'Error',
    json: async () => body,
  } as Response;
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('transcodes API client', () => {
  it('fetchTranscodeDashboard sends X-Admin-Pin header when provided', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse({
        summary: {
          active_count: 1,
          running_count: 1,
          queued_count: 0,
          total_current_bytes: 1024,
          total_current_size_str: '1.0 KB',
          total_estimated_bytes: 2048,
          total_estimated_size_str: '2.0 KB',
          overall_eta_seconds: 60,
          overall_eta_str: '1m 0s',
          hardware_engine: {
            primary: { name: 'RX 560X', adapter: 1, backend: 'AMF', status: 'Active' },
            secondary: { name: 'Vega 8', adapter: 0, backend: 'AMF', status: 'Standby' },
          },
        },
        active_jobs: [],
        recent_jobs: [],
      })
    );

    const data = await fetchTranscodeDashboard('1234');
    expect(data.summary.active_count).toBe(1);
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/transcode/dashboard',
      expect.objectContaining({
        headers: expect.objectContaining({
          'X-Admin-Pin': '1234',
        }),
      })
    );
  });

  it('cancelTranscodeJob issues POST with cancel path', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse({ canceled: true })
    );

    const res = await cancelTranscodeJob('test/movie.mkv', '1234');
    expect(res.canceled).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/transcode/jobs/test%2Fmovie.mkv/cancel',
      expect.objectContaining({
        method: 'POST',
      })
    );
  });

  it('enqueueTranscodeJob posts job admission with preset and priority', async () => {
    fetchMock.mockImplementation(async () =>
      jsonResponse({ job: { id: 1 } })
    );

    const res = await enqueueTranscodeJob('movie.mkv', 'hls:720p', 10, '1234');
    expect(res.job).toEqual({ id: 1 });
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/transcode/jobs/movie.mkv',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ mode: 'hls:720p', priority: 10, force: true }),
      })
    );
  });
});
