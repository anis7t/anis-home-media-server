import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  getCastDevices,
  startCastPlay,
  sendCastControl,
  getCastStatus,
  stopCast,
} from './cast';

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
  fetchMock = vi.fn().mockResolvedValue(jsonResponse({ ok: true }));
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('cast api client', () => {
  it('requests devices without refresh query by default', async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({
        ok: true,
        devices: [
          {
            id: 'dlna:uuid-1',
            name: 'Living Room TV',
            kind: 'dlna',
            model: 'Samsung QLED',
          },
        ],
        scanning: false,
      }),
    );

    const result = await getCastDevices();
    expect(result.ok).toBe(true);
    expect(result.devices).toHaveLength(1);
    expect(result.devices[0].name).toBe('Living Room TV');

    const [url] = fetchMock.mock.calls[0];
    expect(url).toBe('/api/cast/devices');
  });

  it('requests devices with refresh query when force=true', async () => {
    await getCastDevices({ force: true });
    const [url] = fetchMock.mock.calls[0];
    expect(url).toBe('/api/cast/devices?refresh=1');
  });

  it('sends play command with device_id, filename, and position', async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({
        ok: true,
        device: 'Living Room TV',
        url: 'http://192.168.1.5:8000/media/movie.mp4',
        kind: 'dlna',
      }),
    );

    const result = await startCastPlay('dlna:uuid-1', 'movie.mp4', { position: 120 });
    expect(result.ok).toBe(true);
    expect(result.device).toBe('Living Room TV');

    const [url, options] = fetchMock.mock.calls[0];
    expect(url).toBe('/api/cast/play');
    expect(options.method).toBe('POST');
    const body = JSON.parse(options.body as string);
    expect(body).toEqual({
      device_id: 'dlna:uuid-1',
      filename: 'movie.mp4',
      position: 120,
    });
  });

  it('sends control action with optional numeric value', async () => {
    await sendCastControl('dlna:uuid-1', 'seek', 240);
    const [url, options] = fetchMock.mock.calls[0];
    expect(url).toBe('/api/cast/control');
    expect(options.method).toBe('POST');
    const body = JSON.parse(options.body as string);
    expect(body).toEqual({
      device_id: 'dlna:uuid-1',
      action: 'seek',
      value: 240,
    });
  });

  it('queries device status with URL query parameter', async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({
        ok: true,
        state: 'playing',
        position: 45.2,
        duration: 3600,
        volume: 80,
      }),
    );

    const result = await getCastStatus('dlna:uuid-1');
    expect(result.ok).toBe(true);
    expect(result.state).toBe('playing');
    expect(result.position).toBe(45.2);

    const [url] = fetchMock.mock.calls[0];
    expect(url).toBe('/api/cast/status?device_id=dlna%3Auuid-1');
  });

  it('sends stop action on stopCast', async () => {
    await stopCast('dlna:uuid-1');
    const [url, options] = fetchMock.mock.calls[0];
    expect(url).toBe('/api/cast/control');
    const body = JSON.parse(options.body as string);
    expect(body).toEqual({
      device_id: 'dlna:uuid-1',
      action: 'stop',
    });
  });
});
