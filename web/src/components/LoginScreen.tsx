import { useAuth } from '../auth/AuthProvider';
import { GoogleMark } from './GoogleMark';

export function LoginScreen() {
  const { signIn, email } = useAuth();

  return (
    <div className="mx-auto flex min-h-[70vh] max-w-md flex-col items-center justify-center text-center">
      <div
        className="brand-gradient mb-6 flex h-16 w-16 items-center justify-center rounded-2xl text-3xl text-white"
        aria-hidden="true"
      >
        ▶
      </div>

      <h1 className="text-2xl font-bold text-white">Sign in required</h1>
      <p className="mt-2 text-sm leading-relaxed text-white/60">
        This server is protected. Sign in with your Google account to continue.
      </p>

      <button
        type="button"
        onClick={signIn}
        className="card-ring mt-8 flex items-center gap-3 rounded-xl border border-white/15 bg-white/5 px-6 py-3 text-sm font-semibold text-white transition hover:bg-white/10"
      >
        <GoogleMark />
        Continue with Google
      </button>

      {email ? (
        <p className="mt-6 text-xs text-white/40">Signed in as {email}</p>
      ) : null}
    </div>
  );
}

export default LoginScreen;