import { useCallback, useRef, useState } from 'react';
import {
  abortUpload,
  completeUpload,
  initUpload,
  isSupportedMediaFile,
  MAX_UPLOAD_BYTES,
  sendChunk,
  UploadApiError,
  type UploadSuccess,
} from './uploadApi';

export type UploadPhase =
  | 'idle'
  | 'uploading'
  | 'processing'
  | 'success'
  | 'error';

export interface UploadUiState {
  readonly phase: UploadPhase;
  readonly progress: number;
  readonly uploadedBytes: number;
  readonly totalBytes: number;
  readonly speedBytesPerSecond: number | null;
  readonly etaSeconds: number | null;
  readonly error: string | null;
  readonly errorStatus: number | null;
  readonly result: UploadSuccess | null;
}

export interface StartUploadArgs {
  readonly file: File;
  readonly adminPin?: string | null;
  readonly title?: string;
  readonly overwrite?: boolean;
}

const INITIAL_STATE: UploadUiState = {
  phase: 'idle',
  progress: 0,
  uploadedBytes: 0,
  totalBytes: 0,
  speedBytesPerSecond: null,
  etaSeconds: null,
  error: null,
  errorStatus: null,
  result: null,
};

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === 'AbortError';
}

/**
 * Drives one resumable upload. The loop is deliberately sequential: a chunk is
 * acknowledged before the next is sent, and a 409 rewinds to the server's
 * reported offset instead of guessing. The animation/UI never blocks on it.
 */
export function useMediaUpload() {
  const [state, setState] = useState<UploadUiState>(INITIAL_STATE);
  const controllerRef = useRef<AbortController | null>(null);
  const uploadIdRef = useRef<string | null>(null);
  const pinRef = useRef<string | null>(null);
  const busyRef = useRef(false);

  const reset = useCallback(() => {
    controllerRef.current?.abort();
    controllerRef.current = null;
    uploadIdRef.current = null;
    pinRef.current = null;
    busyRef.current = false;
    setState(INITIAL_STATE);
  }, []);

  const abort = useCallback(() => {
    const uploadId = uploadIdRef.current;
    const pin = pinRef.current;
    controllerRef.current?.abort();
    controllerRef.current = null;
    uploadIdRef.current = null;
    pinRef.current = null;
    busyRef.current = false;
    setState(INITIAL_STATE);
    if (uploadId) void abortUpload(uploadId, pin);
  }, []);

  const start = useCallback(
    async ({ file, adminPin, title, overwrite }: StartUploadArgs) => {
      if (busyRef.current) return;

      if (!isSupportedMediaFile(file.name)) {
        setState({
          ...INITIAL_STATE,
          phase: 'error',
          error: 'Unsupported format. Use MP4, MKV, WebM, MOV, AVI, or M4V.',
          errorStatus: 415,
        });
        return;
      }
      if (file.size <= 0) {
        setState({
          ...INITIAL_STATE,
          phase: 'error',
          error: 'The selected file is empty.',
          errorStatus: 400,
        });
        return;
      }
      if (file.size > MAX_UPLOAD_BYTES) {
        setState({
          ...INITIAL_STATE,
          phase: 'error',
          error: 'The selected file exceeds the 20 GiB limit.',
          errorStatus: 413,
        });
        return;
      }

      busyRef.current = true;
      const controller = new AbortController();
      controllerRef.current = controller;
      uploadIdRef.current = null;
      pinRef.current = adminPin ?? null;

      const startedAt = performance.now();
      let resumedFrom = 0;

      setState({
        ...INITIAL_STATE,
        phase: 'uploading',
        totalBytes: file.size,
      });

      try {
        const init = await initUpload(
          file,
          { title, overwrite },
          adminPin,
          controller.signal,
        );
        uploadIdRef.current = init.upload_id;
        let offset = init.offset;
        resumedFrom = offset;

        setState((previous) => ({
          ...previous,
          uploadedBytes: offset,
          progress: file.size > 0 ? offset / file.size : 0,
        }));

        while (offset < file.size) {
          if (controller.signal.aborted) {
            throw new DOMException('Upload cancelled', 'AbortError');
          }

          const chunk = file.slice(
            offset,
            Math.min(offset + init.chunk_size, file.size),
          );
          let attempt = 0;
          let appended = false;

          while (!appended) {
            try {
              const response = await sendChunk(
                init.upload_id,
                offset,
                chunk,
                adminPin,
                (progress) => {
                  const uploaded = offset + progress.loaded;
                  const elapsed = Math.max(
                    (performance.now() - startedAt) / 1000,
                    0.001,
                  );
                  const speed = Math.max(uploaded - resumedFrom, 0) / elapsed;
                  setState((previous) => ({
                    ...previous,
                    uploadedBytes: uploaded,
                    progress:
                      file.size > 0 ? Math.min(uploaded / file.size, 1) : 0,
                    speedBytesPerSecond: speed,
                    etaSeconds:
                      speed > 0
                        ? Math.max(0, (file.size - uploaded) / speed)
                        : null,
                  }));
                },
                controller.signal,
              );
              offset = response.offset;
              appended = true;
            } catch (error) {
              if (controller.signal.aborted) throw error;

              if (
                error instanceof UploadApiError &&
                error.status === 409 &&
                typeof error.currentOffset === 'number'
              ) {
                offset = error.currentOffset;
                setState((previous) => ({
                  ...previous,
                  uploadedBytes: offset,
                  progress:
                    file.size > 0 ? Math.min(offset / file.size, 1) : 0,
                }));
                appended = true;
                continue;
              }

              if (
                error instanceof UploadApiError &&
                (error.status === 0 || error.status >= 500) &&
                attempt < 2
              ) {
                attempt += 1;
                await delay(750 * attempt);
                continue;
              }

              throw error;
            }
          }
        }

        setState((previous) => ({
          ...previous,
          phase: 'processing',
          progress: 1,
          uploadedBytes: file.size,
          etaSeconds: 0,
        }));

        const result = await completeUpload(
          init.upload_id,
          adminPin,
          controller.signal,
        );
        uploadIdRef.current = null;
        setState((previous) => ({
          ...previous,
          phase: 'success',
          progress: 1,
          uploadedBytes: file.size,
          etaSeconds: 0,
          result,
        }));
      } catch (error) {
        if (isAbortError(error) || controller.signal.aborted) {
          setState(INITIAL_STATE);
          return;
        }
        const status = error instanceof UploadApiError ? error.status : null;
        setState((previous) => ({
          ...previous,
          phase: 'error',
          error:
            error instanceof Error
              ? error.message
              : 'The upload failed unexpectedly.',
          errorStatus: status,
        }));
      } finally {
        busyRef.current = false;
        if (controllerRef.current === controller) {
          controllerRef.current = null;
        }
      }
    },
    [],
  );

  return { state, start, abort, reset };
}
