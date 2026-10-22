import { getStoredAdminPin } from '../../lib/api/account';

/** The formats the UI advertises, matching the backend allow-list. */
export const SUPPORTED_UPLOAD_EXTENSIONS = [
  'mp4',
  'mkv',
  'webm',
  'mov',
  'avi',
  'm4v',
] as const;

export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024 * 1024;
export const CHUNK_SIZE = 8 * 1024 * 1024;

export interface ChunkInit {
  readonly success: boolean;
  readonly upload_id: string;
  readonly filename: string;
  readonly size: number;
  readonly offset: number;
  readonly chunk_size: number;
}

export interface ChunkAppend {
  readonly success: boolean;
  readonly upload_id: string;
  readonly offset: number;
  readonly size: number;
  readonly complete: boolean;
}

export interface UploadSuccess {
  readonly success: boolean;
  readonly filename: string;
  readonly title: string;
  readonly year?: number | null;
  readonly needs_transcode: boolean;
  readonly details_url: string;
}

export interface InitUploadOptions {
  readonly title?: string;
  readonly overwrite?: boolean;
}

export interface ChunkProgress {
  readonly loaded: number;
  readonly total: number;
}

/**
 * A structured upload failure. `status === 0` means the transport failed
 * (offline, timeout, DNS) rather than the server answering.
 */
export class UploadApiError extends Error {
  readonly status: number;
  readonly currentOffset?: number;

  constructor(status: number, message: string, currentOffset?: number) {
    super(message);
    this.name = 'UploadApiError';
    this.status = status;
    this.currentOffset = currentOffset;
  }
}

export function isSupportedMediaFile(filename: string): boolean {
  const extension = filename.toLowerCase().split('.').pop() ?? '';
  return (SUPPORTED_UPLOAD_EXTENSIONS as readonly string[]).includes(extension);
}

function adminHeaders(pin?: string | null): Record<string, string> {
  const effectivePin = pin ?? getStoredAdminPin() ?? '';
  return effectivePin ? { 'X-Admin-Pin': effectivePin } : {};
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null
    ? (value as Record<string, unknown>)
    : null;
}

async function toApiError(response: Response): Promise<UploadApiError> {
  let body: unknown = null;
  try {
    body = await response.json();
  } catch {
    body = null;
  }
  const record = asRecord(body);
  const message =
    (typeof record?.error === 'string' && record.error) ||
    (typeof record?.message === 'string' && record.message) ||
    `Upload request failed (${response.status})`;
  const currentOffset =
    typeof record?.current_offset === 'number'
      ? record.current_offset
      : undefined;
  return new UploadApiError(response.status, message, currentOffset);
}

async function requestJson<T>(
  path: string,
  init: RequestInit,
  pin?: string | null,
): Promise<T> {
  const headers: Record<string, string> = {
    ...adminHeaders(pin),
    ...((init.headers as Record<string, string> | undefined) ?? {}),
  };
  if (init.body !== undefined && headers['Content-Type'] === undefined) {
    headers['Content-Type'] = 'application/json';
  }

  const response = await fetch(path, {
    credentials: 'same-origin',
    ...init,
    headers,
  });

  if (!response.ok) throw await toApiError(response);
  return (await response.json()) as T;
}

/** Begin a resumable upload and return the first expected offset. */
export async function initUpload(
  file: File,
  options: InitUploadOptions = {},
  pin?: string | null,
  signal?: AbortSignal,
): Promise<ChunkInit> {
  if (!isSupportedMediaFile(file.name)) {
    throw new UploadApiError(
      415,
      'Unsupported format. Use MP4, MKV, WebM, MOV, AVI, or M4V.',
    );
  }
  if (file.size <= 0) {
    throw new UploadApiError(400, 'The selected file is empty.');
  }
  if (file.size > MAX_UPLOAD_BYTES) {
    throw new UploadApiError(413, 'The selected file exceeds the 20 GiB limit.');
  }

  return requestJson<ChunkInit>(
    '/api/upload/chunk/init',
    {
      method: 'POST',
      signal,
      body: JSON.stringify({
        filename: file.name,
        size: file.size,
        title: options.title?.trim() || undefined,
        overwrite: Boolean(options.overwrite),
      }),
    },
    pin,
  );
}

/**
 * Send one chunk with XHR rather than fetch, because only XHR exposes upload
 * progress on the request body. The server accepts raw bytes with the offset
 * in `X-Upload-Offset`.
 */
export function sendChunk(
  uploadId: string,
  offset: number,
  chunk: Blob,
  pin?: string | null,
  onProgress?: (progress: ChunkProgress) => void,
  signal?: AbortSignal,
): Promise<ChunkAppend> {
  return new Promise<ChunkAppend>((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open(
      'POST',
      `/api/upload/chunk/${encodeURIComponent(uploadId)}`,
    );
    xhr.withCredentials = true;
    xhr.setRequestHeader('Content-Type', 'application/octet-stream');
    xhr.setRequestHeader('X-Upload-Offset', String(offset));
    const effectivePin = pin ?? getStoredAdminPin();
    if (effectivePin) xhr.setRequestHeader('X-Admin-Pin', effectivePin);

    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable && onProgress) {
        onProgress({ loaded: event.loaded, total: event.total });
      }
    };

    xhr.onload = () => {
      const body = parseJson(xhr.responseText);
      if (xhr.status >= 200 && xhr.status < 300) {
        const record = asRecord(body);
        if (record && typeof record.offset === 'number') {
          resolve(body as ChunkAppend);
        } else {
          reject(
            new UploadApiError(
              xhr.status,
              'The server returned a malformed upload response.',
            ),
          );
        }
        return;
      }

      const record = asRecord(body);
      const message =
        (typeof record?.error === 'string' && record.error) ||
        (typeof record?.message === 'string' && record.message) ||
        `Chunk upload failed (${xhr.status})`;
      const currentOffset =
        typeof record?.current_offset === 'number'
          ? record.current_offset
          : undefined;
      reject(new UploadApiError(xhr.status, message, currentOffset));
    };

    xhr.onerror = () =>
      reject(new UploadApiError(0, 'Network error while uploading.'));
    xhr.ontimeout = () =>
      reject(new UploadApiError(0, 'The upload request timed out.'));
    xhr.onabort = () =>
      reject(new DOMException('Upload cancelled', 'AbortError'));
    xhr.timeout = 300_000;

    const onSignalAbort = () => xhr.abort();
    if (signal) {
      if (signal.aborted) {
        xhr.abort();
        return;
      }
      signal.addEventListener('abort', onSignalAbort, { once: true });
    }

    xhr.send(chunk);
  });
}

export async function completeUpload(
  uploadId: string,
  pin?: string | null,
  signal?: AbortSignal,
): Promise<UploadSuccess> {
  return requestJson<UploadSuccess>(
    `/api/upload/chunk/${encodeURIComponent(uploadId)}/complete`,
    { method: 'POST', signal },
    pin,
  );
}

export async function getUploadStatus(
  uploadId: string,
  pin?: string | null,
  signal?: AbortSignal,
): Promise<ChunkInit> {
  return requestJson<ChunkInit>(
    `/api/upload/chunk/${encodeURIComponent(uploadId)}`,
    { signal },
    pin,
  );
}

/** Best-effort removal of a cancelled session. Never throws. */
export async function abortUpload(
  uploadId: string,
  pin?: string | null,
  signal?: AbortSignal,
): Promise<void> {
  try {
    await fetch(`/api/upload/chunk/${encodeURIComponent(uploadId)}`, {
      method: 'DELETE',
      credentials: 'same-origin',
      headers: adminHeaders(pin),
      signal,
    });
  } catch {
    // A cancelled upload must never surface a second failure.
  }
}
