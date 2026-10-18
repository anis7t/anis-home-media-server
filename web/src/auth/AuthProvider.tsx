import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';

import { fetchMe } from '../lib/api/account';
import { AUTH_LOCKED_EVENT } from './authEvents';
import AdminPinSignInModal from '../components/AdminPinSignInModal';

export { AUTH_LOCKED_EVENT, notifyAuthLocked } from './authEvents';

export interface Account {
  readonly authenticated: boolean;
  readonly email: string | null;
  readonly name: string | null;
  readonly picture: string | null;
  readonly role: string | null;
  readonly oauthConfigured: boolean;
}

export interface AuthState extends Account {
  readonly loading: boolean;
  readonly refresh: () => Promise<void>;
  /** True once the server has refused an API call with 401. */
  readonly locked: boolean;
  readonly signIn: () => void;
  readonly signOut: () => void;
  readonly openPinSignIn: () => void;
}

const UNKNOWN: Account = {
  authenticated: false,
  email: null,
  name: null,
  picture: null,
  role: null,
  oauthConfigured: true,
};

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [account, setAccount] = useState<Account>(UNKNOWN);
  const [loading, setLoading] = useState(true);
  const [locked, setLocked] = useState(false);
  const [pinModalOpen, setPinModalOpen] = useState(false);

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
        oauthConfigured: body.oauth_configured ?? true,
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

  const openPinSignIn = useCallback(() => {
    setPinModalOpen(true);
  }, []);

  /*
   * A top-level navigation, not fetch: the Google redirect must be a real
   * browser navigation so the session cookie is set on this origin.
   */
  const signIn = useCallback(() => {
    if (!account.oauthConfigured) {
      setPinModalOpen(true);
      return;
    }
    window.location.assign('/auth/google?next=' + encodeURIComponent(window.location.pathname));
  }, [account.oauthConfigured]);

  const signOut = useCallback(() => {
    if (typeof sessionStorage !== 'undefined') {
      sessionStorage.removeItem('ms_admin_pin');
      sessionStorage.removeItem('ms_admin_unlocked');
      sessionStorage.removeItem('ms_admin_manual_lock');
    }
    window.location.assign('/auth/logout');
  }, []);

  const value = useMemo<AuthState>(
    () => ({ ...account, loading, locked, refresh, signIn, signOut, openPinSignIn }),
    [account, loading, locked, refresh, signIn, signOut, openPinSignIn],
  );

  return (
    <AuthContext.Provider value={value}>
      {children}
      <AdminPinSignInModal
        isOpen={pinModalOpen}
        onClose={() => setPinModalOpen(false)}
        onSuccess={refresh}
        oauthConfigured={account.oauthConfigured}
      />
    </AuthContext.Provider>
  );
}

export function useAuth(): AuthState {
  const context = useContext(AuthContext);
  if (!context) throw new Error('useAuth must be used inside <AuthProvider>');
  return context;
}