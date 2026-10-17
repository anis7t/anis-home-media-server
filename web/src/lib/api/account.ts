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