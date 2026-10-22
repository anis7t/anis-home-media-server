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

export interface TokenRecord {
  readonly id: number;
  readonly user_id: number;
  readonly label: string;
  readonly created_at: number;
  readonly last_used_at: number | null;
  readonly expires_at: number | null;
  readonly revoked_at: number | null;
}

export interface MintedToken {
  readonly token: string;
  readonly pairing_url: string;
  readonly id: number;
  readonly label: string;
  readonly expires_at: number | null;
  readonly warning: string;
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

export function fetchMe(): Promise<AccountResponse> {
  return accountRequest<AccountResponse>('/api/auth/me');
}

export function loginWithPin(pin: string): Promise<{ success: boolean; user?: any }> {
  return accountRequest<{ success: boolean; user?: any }>('/api/auth/login-pin', {
    method: 'POST',
    body: JSON.stringify({ pin }),
  });
}

export function listTokens(): Promise<{ tokens: TokenRecord[] }> {
  return accountRequest<{ tokens: TokenRecord[] }>('/api/auth/tokens');
}

export function mintToken(label: string): Promise<MintedToken> {
  return accountRequest<MintedToken>('/api/auth/tokens', {
    method: 'POST',
    body: JSON.stringify({ label }),
  });
}

export function revokeToken(id: number): Promise<{ revoked: number }> {
  return accountRequest<{ revoked: number }>(`/api/auth/tokens/${id}`, { method: 'DELETE' });
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

export function getStoredAdminPin(): string | null {
  try {
    if (typeof sessionStorage !== 'undefined' && typeof sessionStorage?.getItem === 'function') {
      const pin = sessionStorage.getItem('ms_admin_pin');
      if (pin) return pin;
    }
  } catch {
    // ignore
  }
  try {
    if (typeof localStorage !== 'undefined' && typeof localStorage?.getItem === 'function') {
      const pin = localStorage.getItem('admin_pin');
      if (pin) return pin;
    }
  } catch {
    // ignore
  }
  return null;
}

async function accountRequest<T>(path: string, options: RequestInit = {}): Promise<T> {
  const pin = getStoredAdminPin();
  let headers: Record<string, string> | undefined = undefined;

  if (options.body) {
    headers = { 'Content-Type': 'application/json' };
  }
  if (pin) {
    headers = { ...(headers || {}), 'X-Admin-Pin': pin };
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
    if (response.status === 401) notifyAuthLocked();
    const error = new Error(`Request failed: ${response.status}`) as Error & {
      status?: number;
    };
    error.status = response.status;
    throw error;
  }
  return (await response.json()) as T;
}

export type { ApiError };