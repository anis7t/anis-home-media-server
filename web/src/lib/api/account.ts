import { notifyAuthLocked } from '../../auth/AuthProvider';
import type { ApiError } from './client';

export interface AccountResponse {
  readonly authenticated: boolean;
  readonly email?: string;
  readonly name?: string;
  readonly picture?: string;
  readonly role?: string;
  readonly oauth_configured?: boolean;
}

export interface QrSession {
  readonly qr_id: string;
  readonly code: string;
  readonly sig: string;
  readonly expires_at: number;
  /** Full URL to embed in the QR code (includes code + sig params) */
  readonly qr_url: string;
  /** Human-readable URL for the TV display text */
  readonly login_url: string;
}

export interface AdminOtpGenerateResponse {
  readonly otp: string;
  readonly expires_at: string;
  readonly expires_in: number;
}

export interface AdminOtpVerifyResponse {
  readonly success: boolean;
  readonly admin: boolean;
  readonly session_token?: string;
  readonly user?: any;
  readonly error?: string;
}

export interface AdminOtpRevokeResponse {
  readonly success: boolean;
  readonly revoked: number;
}

export function generateAdminOtp(): Promise<AdminOtpGenerateResponse> {
  return accountRequest<AdminOtpGenerateResponse>('/api/admin/otp/generate', {
    method: 'POST',
  });
}

export async function verifyAdminOtp(otp: string): Promise<AdminOtpVerifyResponse> {
  const res = await fetch('/api/admin/otp/verify', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ otp: otp.trim() }),
  });

  const data = await res.json().catch(() => ({}));
  if (res.ok && data.success) {
    return data;
  }
  return {
    success: false,
    admin: false,
    error: data.error || 'Invalid or expired access code',
  };
}

export function revokeAdminOtp(): Promise<AdminOtpRevokeResponse> {
  return accountRequest<AdminOtpRevokeResponse>('/api/admin/otp/revoke', {
    method: 'POST',
  });
}

export function fetchMe(): Promise<AccountResponse> {
  return accountRequest<AccountResponse>('/api/auth/me');
}

export function loginWithPin(pin: string): Promise<{ success: boolean; user?: any }> {
  return verifyAdminOtp(pin);
}

/** Create a new QR pair session. Called by the TV/browser when showing the sign-in panel. */
export function createQrSession(): Promise<QrSession> {
  return accountRequest<QrSession>('/api/auth/qr', { method: 'POST' });
}

/**
 * Confirm a QR pair session from the phone side.
 * The caller must already be signed in (session cookie present).
 */
export function confirmQrSession(
  qrId: string,
  deviceName: string,
  opts: { code?: string; sig?: string },
): Promise<{ success: boolean; message: string }> {
  return accountRequest<{ success: boolean; message: string }>(
    `/api/auth/qr/${encodeURIComponent(qrId)}/confirm`,
    {
      method: 'POST',
      body: JSON.stringify({
        code: opts.code ?? '',
        sig: opts.sig,
        device_name: deviceName,
      }),
    },
  );
}

/**
 * Resolve a manually typed 5-char code on the phone to an active `qr_id`.
 */
export function lookupQrCode(code: string): Promise<{ qr_id: string; code: string }> {
  return accountRequest<{ qr_id: string; code: string }>('/api/auth/qr/lookup', {
    method: 'POST',
    body: JSON.stringify({ code }),
  });
}

export function listAllowlist(): Promise<{
  stored: string[];
  environment: string[];
  effective: string[];
}> {
  return accountRequest('/api/auth/allowlist');
}

export function saveAllowlist(emails: string[]): Promise<{ stored: string[] }> {
  return accountRequest('/api/auth/allowlist', {
    method: 'POST',
    body: JSON.stringify({ emails }),
  });
}

/**
 * Legacy static PIN storage has been permanently retired.
 * This helper returns null to ensure no plaintext PIN is read.
 */
export function getStoredAdminPin(): string | null {
  return null;
}

async function accountRequest<T>(path: string, options: RequestInit = {}): Promise<T> {
  let headers: Record<string, string> | undefined = undefined;

  if (options.body) {
    headers = { 'Content-Type': 'application/json' };
  }
  if (options.headers) {
    headers = { ...(headers || {}), ...(options.headers as Record<string, string>) };
  }

  const response = await fetch(path, {
    credentials: 'same-origin',
    ...options,
    headers,
  });

  if (!response.ok) {
    /*
     * A 401 is not just an error, it is a state change: this client can no
     * longer do anything until someone signs in. Tell the app rather than
     * letting each screen render its own failure.
     */
    if (response.status === 401 && !path.includes('/otp/verify')) {
      notifyAuthLocked();
    }
    const error = new Error(`Request failed: ${response.status}`) as Error & {
      status?: number;
    };
    error.status = response.status;
    throw error;
  }
  return (await response.json()) as T;
}

export type { ApiError };