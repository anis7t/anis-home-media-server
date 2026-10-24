import { ApiError, MEDIA_PROBE_TIMEOUT_MS, request } from './client';

export interface DriveUsage {
  readonly drive: string;
  readonly free_str: string;
  readonly total_str: string;
  readonly used_str: string;
  readonly percent: number;
}

export interface StorageAuditData {
  readonly storage: {
    readonly free_bytes?: number;
    readonly free_str?: string;
    readonly total_bytes?: number;
    readonly total_str?: string;
    readonly percent?: number;
    readonly drives?: readonly DriveUsage[];
  };
  readonly audit: {
    readonly total_orphaned_dirs?: number;
    readonly total_orphaned_bytes?: number;
    readonly orphaned_hls_dirs?: readonly string[];
    readonly total_active_bytes?: number;
    readonly total_active_dirs?: number;
    readonly active_hls?: ReadonlyArray<{
      readonly source_file: string;
      readonly size_bytes: number;
      readonly name: string;
      readonly path: string;
    }>;
  };
}

export interface StorageSettings {
  readonly retention_policy: string;
  readonly archive_dir: string;
  readonly allowed_policies: readonly string[];
}

export interface MovieItem {
  readonly filename: string;
  readonly title: string;
  readonly year?: number;
  readonly duration?: number;
  readonly poster?: string;
  readonly percent?: number;
  readonly position?: number;
  readonly rating?: number;
  readonly runtime?: number;
  readonly updated_at?: string;
  readonly hls_cached?: boolean;
  readonly needs_transcode?: boolean;
}

export interface AdminVerifyResponse {
  readonly success: boolean;
  readonly admin?: boolean;
  readonly method?: string;
  readonly error?: string;
}

export interface ArchiveResponse {
  readonly success: boolean;
  readonly error?: string;
  readonly result?: {
    readonly message?: string;
    readonly target?: string;
  };
}

export interface PurgeOrphansResponse {
  readonly success: boolean;
  readonly result?: {
    readonly purged: number;
    readonly bytes_reclaimed?: number;
  };
}

export function formatBytes(bytes?: number): string {
  if (!bytes || bytes <= 0) return '0 MB';
  const gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1) return `${gb.toFixed(2)} GB`;
  const mb = bytes / (1024 * 1024);
  return `${mb.toFixed(1)} MB`;
}

function adminHeaders(pin?: string): Record<string, string> {
  const headers: Record<string, string> = {};
  const effectivePin =
    pin ||
    (typeof sessionStorage !== 'undefined'
      ? sessionStorage.getItem('ms_admin_pin') || ''
      : '');
  if (effectivePin) {
    headers['X-Admin-Pin'] = effectivePin;
  }
  return headers;
}

export async function fetchManageMovies(signal?: AbortSignal): Promise<MovieItem[]> {
  const body = await request<{ movies?: MovieItem[] } | MovieItem[]>('/api/movies', { signal });
  if (Array.isArray(body)) return body;
  return body.movies ?? [];
}

export function fetchStorageSettings(adminPin?: string, signal?: AbortSignal): Promise<StorageSettings> {
  return request<StorageSettings>('/api/storage/settings', {
    headers: adminHeaders(adminPin),
    signal,
  });
}

export function fetchStorageAudit(adminPin?: string, signal?: AbortSignal): Promise<StorageAuditData> {
  return request<StorageAuditData>('/api/storage/audit', {
    headers: adminHeaders(adminPin),
    timeoutMs: MEDIA_PROBE_TIMEOUT_MS,
    signal,
  });
}

export async function verifyAdminPin(pin: string, signal?: AbortSignal): Promise<AdminVerifyResponse> {
  try {
    return await request<AdminVerifyResponse>('/api/admin/verify', {
      method: 'POST',
      body: { pin },
      signal,
    });
  } catch (err) {
    if (err instanceof ApiError) {
      const errorMsg =
        err.body && typeof err.body === 'object' && 'error' in err.body && typeof err.body.error === 'string'
          ? err.body.error
          : err.message;
      return { success: false, error: errorMsg };
    }
    throw err;
  }
}

export function updateStoragePolicy(
  newPolicy: string,
  adminPin?: string,
  signal?: AbortSignal,
): Promise<{ success: boolean; retention_policy: string }> {
  return request<{ success: boolean; retention_policy: string }>('/api/storage/settings', {
    method: 'POST',
    headers: adminHeaders(adminPin),
    body: { retention_policy: newPolicy },
    signal,
  });
}

export function purgeOrphanedCaches(
  adminPin?: string,
  signal?: AbortSignal,
): Promise<PurgeOrphansResponse> {
  return request<PurgeOrphansResponse>('/api/storage/purge-orphans', {
    method: 'POST',
    headers: adminHeaders(adminPin),
    signal,
  });
}

export async function triggerLibraryScan(
  adminPin?: string,
  signal?: AbortSignal,
): Promise<{ success: boolean; status?: string; message?: string }> {
  const body = await request<{ status?: string; success?: boolean; message?: string }>('/api/scan', {
    method: 'POST',
    headers: adminHeaders(adminPin),
    signal,
  });
  return {
    success: body.success ?? (body.status === 'scanning' || body.status === 'idle'),
    status: body.status,
    message: body.message,
  };
}

export function archiveMovieMedia(
  filename: string,
  adminPin?: string,
  signal?: AbortSignal,
): Promise<ArchiveResponse> {
  return request<ArchiveResponse>(`/api/storage/archive/${encodeURIComponent(filename)}`, {
    method: 'POST',
    headers: adminHeaders(adminPin),
    signal,
  });
}

export function deleteMovieMedia(
  filename: string,
  adminPin?: string,
  signal?: AbortSignal,
): Promise<{ success: boolean; message?: string; error?: string }> {
  return request<{ success: boolean; message?: string; error?: string }>(
    `/api/media/${encodeURIComponent(filename)}`,
    {
      method: 'DELETE',
      headers: adminHeaders(adminPin),
      signal,
    },
  );
}

export interface ChangeAdminPinResponse {
  readonly success: boolean;
  readonly error?: string;
}

export async function changeAdminPin(
  params: { currentPin?: string; newPin: string },
  signal?: AbortSignal,
): Promise<ChangeAdminPinResponse> {
  try {
    return await request<{ success: boolean }>('/api/admin/pin', {
      method: 'POST',
      headers: adminHeaders(params.currentPin),
      body: {
        current_pin: params.currentPin,
        new_pin: params.newPin,
      },
      signal,
    });
  } catch (err) {
    if (err instanceof ApiError) {
      const errorMsg =
        err.body && typeof err.body === 'object' && 'error' in err.body && typeof err.body.error === 'string'
          ? err.body.error
          : err.message;
      return { success: false, error: errorMsg };
    }
    throw err;
  }
}
