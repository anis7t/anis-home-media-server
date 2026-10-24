import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  initUpload,
  isSupportedMediaFile,
  sendChunk,
  UploadApiError,
} from './uploadApi';

let fetchMock: ReturnType<typeof vi.fn>;

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : 'Error',
    json: async () => body,
  } as Response;
}

class FakeXhr {
  static last: FakeXhr | null = null;
  static nextStatus = 200;
  static nextBody: unknown = {};

  upload = { onprogress: null as ((event: ProgressEvent) => void) | null };
  status = 200;
  responseText = '';
  timeout = 0;
  withCredentials = false;
  onload: (() => void) | null = null;
  onerror: (() => void) | null = null;
  ontimeout: (() => void) | null = null;
  onabort: (() => void) | null = null;
  open = vi.fn();
  setRequestHeader = vi.fn();
  abort = vi.fn(() => this.onabort?.());
  send = vi.fn(() => this.onload?.());

  constructor() {
    FakeXhr.last = this;
    this.status = FakeXhr.nextStatus;
    this.responseText = JSON.stringify(FakeXhr.nextBody);
  }
}

beforeEach(() => {
  sessionStorage.clear();
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
  FakeXhr.last = null;
  FakeXhr.nextStatus = 200;
  FakeXhr.nextBody = {};
  vi.stubGlobal('XMLHttpRequest', FakeXhr);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('uploadApi', () => {
  it('sends the admin PIN header and trims the optional title', async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({
        success: true,
        upload_id: 'upload-1',
        filename: 'Movie.mp4',
        size: 3,
        offset: 0,
        chunk_size: 8 * 1024 * 1024,
      }),
    );

    const file = new File(['abc'], 'Movie.mp4', { type: 'video/mp4' });
    const result = await initUpload(
      file,
      { title: '  My Movie  ', overwrite: true },
      '97531',
    );

    expect(result.upload_id).toBe('upload-1');
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/upload/chunk/init',
      expect.objectContaining({
        method: 'POST',
        credentials: 'same-origin',
        headers: expect.objectContaining({
          'Content-Type': 'application/json',
          'X-Admin-Pin': '97531',
        }),
      }),
    );

    const request = fetchMock.mock.calls[0][1] as RequestInit;
    expect(JSON.parse(String(request.body))).toEqual({
      filename: 'Movie.mp4',
      size: 3,
      title: 'My Movie',
      overwrite: true,
    });
  });

  it('does not invent an admin PIN when none is supplied', async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({
        success: true,
        upload_id: 'upload-2',
        filename: 'Movie.mkv',
        size: 5,
        offset: 0,
        chunk_size: 8 * 1024 * 1024,
      }),
    );

    const file = new File(['abcde'], 'Movie.mkv', { type: 'video/x-matroska' });
    await initUpload(file, {}, null);

    const request = fetchMock.mock.calls[0][1] as RequestInit;
    expect(request.headers).not.toHaveProperty('X-Admin-Pin');
  });

  it('maps a server refusal to a structured 403 error', async () => {
    fetchMock.mockResolvedValue(
      jsonResponse({ error: 'Forbidden: admin authorization required' }, 403),
    );

    const file = new File(['abc'], 'Movie.mp4', { type: 'video/mp4' });
    await expect(initUpload(file, {}, 'wrong-pin')).rejects.toMatchObject({
      name: 'UploadApiError',
      status: 403,
      message: 'Forbidden: admin authorization required',
    });
    await expect(
      initUpload(file, {}, 'wrong-pin'),
    ).rejects.toBeInstanceOf(UploadApiError);
  });

  it('accepts only the documented media extensions', () => {
    for (const name of ['a.mp4', 'b.mkv', 'c.webm', 'd.mov', 'e.avi', 'f.m4v']) {
      expect(isSupportedMediaFile(name)).toBe(true);
    }
    expect(isSupportedMediaFile('payload.exe')).toBe(false);
    expect(isSupportedMediaFile('archive.zip')).toBe(false);
    expect(isSupportedMediaFile('no-extension')).toBe(false);
  });

  it('sends chunks with the offset and parses the acknowledgement', async () => {
    FakeXhr.nextStatus = 200;
    FakeXhr.nextBody = {
      success: true,
      upload_id: 'upload-3',
      offset: 3,
      size: 3,
      complete: true,
    };

    const result = await sendChunk(
      'upload-3',
      0,
      new Blob(['abc']),
      '97531',
    );

    expect(result).toMatchObject({ offset: 3, complete: true });
    expect(FakeXhr.last?.open).toHaveBeenCalledWith(
      'POST',
      '/api/upload/chunk/upload-3',
    );
    expect(FakeXhr.last?.setRequestHeader).toHaveBeenCalledWith(
      'X-Upload-Offset',
      '0',
    );
    expect(FakeXhr.last?.setRequestHeader).toHaveBeenCalledWith(
      'X-Admin-Pin',
      '97531',
    );
  });

  it('surfaces the server offset on a 409 conflict', async () => {
    FakeXhr.nextStatus = 409;
    FakeXhr.nextBody = {
      error: 'Offset mismatch',
      current_offset: 5,
    };

    await expect(
      sendChunk('upload-4', 0, new Blob(['abc']), '97531'),
    ).rejects.toMatchObject({
      name: 'UploadApiError',
      status: 409,
      currentOffset: 5,
    });
  });
});
