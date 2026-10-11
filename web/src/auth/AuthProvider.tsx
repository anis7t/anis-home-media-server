import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';

import { fetchMe } from '../lib/api/account';
import { AUTH_LOCKED_EVENT } from './authEvents';

export { AUTH_LOCKED_EVENT, notifyAuthLocked } from './authEvents';

export interface Account {
  readonly authenticated: boolean;
  readonly email: string | null;
  readonly name: string | null;
  readonly picture: string | null;
  readonly role: string | null;
}

interface AuthState extends Account {
  readonly loading: boolean;
  readonly refresh: () => Promise<void>;
  /** True once the server has refused an API call with 401. */
  readonly locked: boolean;
  readonly signIn: () => void;
  readonly signOut: () => void;
}

const UNKNOWN: Account = { authenticated: false, email: null, name: null, picture: null, role: null };

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [account, setAccount] = useState<Account>(UNKNOWN);
  const [loading, setLoading] = useState(true);
  const [locked, setLocked] = useState(false);

  const refresh = useCallback(async () => {
    try {
      const body = await fetchMe();
      // Normalise undefined -> null so the shape matches Account exactly;
      // otherwise the state type lies about what the server sends.
      setAccount({
        authenticated: body.authenticated,
        email: body.email ?? null,
        name: body.name ?? null,
        picture: body.picture ?? null,
        role: body.role ?? null,
      });
    } catch {
      setAccount(UNKNOWN);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    const onLocked = () => setLocked(true);
    window.addEventListener(AUTH_LOCKED_EVENT, onLocked);
    return () => window.removeEventListener(AUTH_LOCKED_EVENT, onLocked);
  }, []);

  /*
   * A top-level navigation, not fetch: the Google redirect must be a real
   * browser navigation so the session cookie is set on this origin.
   */
  const signIn = useCallback(() => {
    window.location.assign('/auth/google?next=' + encodeURIComponent(window.location.pathname));
  }, []);

  const signOut = useCallback(() => {
    window.location.assign('/auth/logout');
  }, []);

  const value = useMemo<AuthState>(
    () => ({ ...account, loading, locked, refresh, signIn, signOut }),
    [account, loading, locked, refresh, signIn, signOut],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const context = useContext(AuthContext);
  if (!context) throw new Error('useAuth must be used inside <AuthProvider>');
  return context;
}