import { useEffect, useState, useCallback } from 'react';

import { useAuth } from '../../auth/AuthProvider';
import Avatar from '../../components/Avatar';
import { Icon } from '../../components/icons';
import { QrSignInPanel } from '../../components/QrSignInPanel';
import {
  generateAdminOtp,
  revokeAdminOtp,
  type AdminOtpGenerateResponse,
} from '../../lib/api/account';

export function AccountPage() {
  const {
    authenticated,
    loading: authLoading,
    email,
    name,
    role,
    signIn,
    signOut,
    oauthConfigured,
    openPinSignIn,
  } = useAuth();

  const [otpData, setOtpData] = useState<AdminOtpGenerateResponse | null>(null);
  const [otpTimeLeft, setOtpTimeLeft] = useState<number>(0);
  const [otpLoading, setOtpLoading] = useState<boolean>(false);
  const [otpError, setOtpError] = useState<string | null>(null);
  const [otpCopied, setOtpCopied] = useState<boolean>(false);
  const [otpRevoked, setOtpRevoked] = useState<boolean>(false);

  // Active countdown timer for generated OTP
  useEffect(() => {
    if (!otpData || otpTimeLeft <= 0) return;
    const interval = setInterval(() => {
      setOtpTimeLeft((prev) => {
        if (prev <= 1) {
          clearInterval(interval);
          return 0;
        }
        return prev - 1;
      });
    }, 1000);
    return () => clearInterval(interval);
  }, [otpData, otpTimeLeft]);

  const handleGenerateOtp = useCallback(async () => {
    setOtpLoading(true);
    setOtpError(null);
    setOtpCopied(false);
    setOtpRevoked(false);
    try {
      const res = await generateAdminOtp();
      setOtpData(res);
      setOtpTimeLeft(res.expires_in || 300);
    } catch (err: any) {
      setOtpError(err.message || 'Failed to generate access code');
    } finally {
      setOtpLoading(false);
    }
  }, []);

  const handleCopyOtp = useCallback(async () => {
    if (!otpData?.otp) return;
    try {
      await navigator.clipboard.writeText(otpData.otp);
      setOtpCopied(true);
      setTimeout(() => setOtpCopied(false), 3000);
    } catch {
      // Ignore clipboard write failures
    }
  }, [otpData]);

  const handleRevokeOtp = useCallback(async () => {
    setOtpLoading(true);
    setOtpError(null);
    try {
      await revokeAdminOtp();
      setOtpData(null);
      setOtpTimeLeft(0);
      setOtpRevoked(true);
      setTimeout(() => setOtpRevoked(false), 5000);
    } catch (err: any) {
      setOtpError(err.message || 'Failed to revoke access code');
    } finally {
      setOtpLoading(false);
    }
  }, []);

  const formatCountdown = (seconds: number) => {
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  };

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    if (params.get('error') === 'oauth_unconfigured') {
      openPinSignIn();
    }
  }, [openPinSignIn]);

  return (
    <div className="mx-auto max-w-3xl space-y-8 animate-fade-in">
      {/* Account Profile Header Card */}
      <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-6">
          <div className="flex items-center gap-4">
            <div className="relative">
              <Avatar size="lg" label={authenticated ? (name ?? email ?? 'Account') : 'Guest'} />
              <div
                className={`absolute -bottom-1 -right-1 flex h-5 w-5 items-center justify-center rounded-full ring-2 ring-obsidian-900 ${
                  authenticated ? 'bg-emerald-500' : 'bg-amber-500'
                }`}
                title={authenticated ? 'Online' : 'Guest'}
              >
                <span className="h-2 w-2 rounded-full bg-white"></span>
              </div>
            </div>
            <div className="min-w-0">
              <div className="flex items-center gap-2.5">
                <h1 className="text-2xl font-bold tracking-tight text-white">Account</h1>
                {authenticated && role ? (
                  <span className="rounded-full bg-brand-500/20 px-2.5 py-0.5 text-xs font-semibold uppercase tracking-wider text-brand-300 border border-brand-500/30">
                    {role}
                  </span>
                ) : (
                  <span className="rounded-full bg-white/10 px-2.5 py-0.5 text-xs font-semibold text-white/60 border border-white/10">
                    Guest Mode
                  </span>
                )}
              </div>
              {authenticated ? (
                <>
                  <p className="mt-1 text-sm text-white/60">
                    Signed in as <span className="text-white/90 font-medium">{name ?? email}</span>
                  </p>
                  {email ? <p className="text-xs text-white/40">{email}</p> : null}
                </>
              ) : (
                <>
                  <p className="mt-1 text-sm text-white/60">
                    Not signed in · Browsing as a local guest
                  </p>
                  {!oauthConfigured && (
                    <p className="mt-1 text-xs text-amber-400/80">
                      Google Sign-In is not configured on this server.
                    </p>
                  )}
                </>
              )}
            </div>
          </div>

          {authenticated && (
            <button
              type="button"
              onClick={signOut}
              className="self-start sm:self-auto rounded-full border border-white/15 bg-white/5 px-5 py-2 text-xs font-semibold text-white/80 shadow-sm transition hover:border-white/30 hover:bg-white/10 hover:text-white active:scale-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-400"
            >
              Sign out
            </button>
          )}
        </div>
      </section>

      {/* QR Device Sign-In Panel */}
      {!authLoading && !authenticated && (
        <section aria-label="QR Device Sign-In" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl">
          <div className="mb-6">
            <h2 className="text-xl font-bold text-white">Sign In to Anis&apos; Home Media Server</h2>
            <p className="mt-1 text-xs text-white/50">
              Scan with your phone to pair this device, or sign in directly below.
            </p>
          </div>
          <QrSignInPanel
            onGoogleSignIn={signIn}
            onPinSignIn={openPinSignIn}
            oauthConfigured={oauthConfigured}
          />
        </section>
      )}

      {/* Session Management Section - Active Session only */}
      {authenticated && (
        <section aria-labelledby="session-heading" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-4">
          <h2 id="session-heading" className="text-lg font-bold text-white">
            Active Session
          </h2>
          <p className="text-xs text-white/50">
            Sign out will clear your session cookie on this browser. You can sign back in at any time with Google Sign-In.
          </p>
          <button
            type="button"
            onClick={signOut}
            className="card-ring rounded-full border border-white/15 bg-white/5 px-5 py-2.5 text-sm font-semibold text-white hover:bg-white/10 active:scale-95 transition"
          >
            Sign out
          </button>
        </section>
      )}

      {/* Admin Security Section - Google Administrator only */}
      {authenticated && role === 'admin' && (
        <section aria-labelledby="admin-security-heading" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6">
          <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
            <div>
              <h2 id="admin-security-heading" className="text-lg font-bold text-white flex items-center gap-2">
                <Icon name="shield" size={18} className="text-brand-400" />
                <span>Admin Security</span>
              </h2>
              <p className="mt-1 text-xs text-white/60">
                Generate a single-use 6-digit access code (OTP) to authorize administrative access on another device or TV.
              </p>
            </div>
            {!otpData || otpTimeLeft <= 0 ? (
              <button
                type="button"
                onClick={handleGenerateOtp}
                disabled={otpLoading}
                className="card-ring rounded-full brand-gradient px-5 py-2.5 text-xs font-bold text-white shadow-md hover:scale-[1.02] active:scale-[0.98] transition flex items-center gap-2 cursor-pointer disabled:opacity-50 self-start sm:self-auto"
              >
                <Icon name="shield" size={14} />
                <span>{otpLoading ? 'Generating…' : 'Generate Admin Access Code'}</span>
              </button>
            ) : null}
          </div>

          {otpError && (
            <div className="rounded-2xl border border-rose-500/30 bg-rose-500/10 p-4 text-xs text-rose-300">
              ⚠️ {otpError}
            </div>
          )}

          {otpRevoked && (
            <div className="rounded-2xl border border-amber-500/30 bg-amber-500/10 p-4 text-xs text-amber-300">
              ✓ All outstanding access codes revoked.
            </div>
          )}

          {/* Active OTP Display Card */}
          {otpData && otpTimeLeft > 0 ? (
            <div className="rounded-2xl border border-brand-500/30 bg-brand-500/5 p-6 space-y-5 animate-scale-in">
              <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
                <div className="flex items-center gap-2">
                  <span className="flex h-2.5 w-2.5 rounded-full bg-emerald-500 animate-pulse" />
                  <span className="text-xs font-semibold text-brand-300">
                    Active Access Code
                  </span>
                </div>
                <div className="flex items-center gap-2 text-xs font-mono font-bold text-amber-400 bg-amber-500/10 px-3 py-1.5 rounded-full border border-amber-500/20">
                  <span>⏱️ Expires in:</span>
                  <span>{formatCountdown(otpTimeLeft)}</span>
                </div>
              </div>

              {/* Six Large Monospace Digits */}
              <div className="flex items-center justify-center gap-2 sm:gap-3 py-2">
                {otpData.otp.split('').map((digit, idx) => (
                  <div
                    key={idx}
                    className="flex h-14 w-11 sm:h-16 sm:w-13 items-center justify-center rounded-2xl border border-brand-500/40 bg-obsidian-950 font-mono text-2xl sm:text-3xl font-extrabold text-white shadow-lg tracking-wider"
                  >
                    {digit}
                  </div>
                ))}
              </div>

              {/* Warning Notice */}
              <p className="text-center text-xs text-white/60">
                🔒 Single-use only. Valid for 5 minutes. Enter this code on another screen or TV to unlock administrator privileges.
              </p>

              {/* Actions: Copy & Revoke */}
              <div className="flex items-center justify-center gap-3 pt-2">
                <button
                  type="button"
                  onClick={handleCopyOtp}
                  className="card-ring rounded-full border border-white/20 bg-white/10 hover:bg-white/15 px-5 py-2 text-xs font-semibold text-white transition flex items-center gap-1.5 cursor-pointer active:scale-95"
                >
                  <Icon name="copy" size={13} />
                  <span>{otpCopied ? '✓ Copied!' : 'Copy Code'}</span>
                </button>

                <button
                  type="button"
                  onClick={handleRevokeOtp}
                  disabled={otpLoading}
                  className="card-ring rounded-full border border-rose-500/30 bg-rose-500/10 hover:bg-rose-500/20 px-5 py-2 text-xs font-semibold text-rose-300 transition flex items-center gap-1.5 cursor-pointer active:scale-95 disabled:opacity-50"
                >
                  <Icon name="x" size={13} />
                  <span>Revoke Code</span>
                </button>
              </div>
            </div>
          ) : null}

          {/* Expired State */}
          {otpData && otpTimeLeft <= 0 ? (
            <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-6 text-center space-y-4">
              <p className="text-sm font-semibold text-amber-300">
                ⌛ Access code expired
              </p>
              <p className="text-xs text-white/50 max-w-sm mx-auto">
                The one-time access code has expired and can no longer be used. Generate a new code to authorize an administrative session.
              </p>
              <button
                type="button"
                onClick={handleGenerateOtp}
                disabled={otpLoading}
                className="card-ring rounded-full brand-gradient px-5 py-2 text-xs font-bold text-white shadow-md hover:scale-[1.02] active:scale-[0.98] transition cursor-pointer"
              >
                Generate New Code
              </button>
            </div>
          ) : null}
        </section>
      )}
    </div>
  );
}

export default AccountPage;

