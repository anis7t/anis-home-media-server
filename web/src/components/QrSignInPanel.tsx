import { useEffect, useRef } from 'react';
import { useQrSession } from '../hooks/useQrSession';

interface QrSignInPanelProps {
  /** Called when the user wants to sign in directly on this device with Google */
  onGoogleSignIn: () => void;
  /** Called when the user wants to use Admin PIN sign-in */
  onPinSignIn: () => void;
  oauthConfigured: boolean;
}

function formatCountdown(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  if (m > 0) return `${m}:${String(s).padStart(2, '0')}`;
  return `0:${String(s).padStart(2, '0')}`;
}

/**
 * QR sign-in panel shown on the Account page when the user is not authenticated.
 * Displays a QR code, 5-char pair code, countdown, and manual URL
 * so phones can sign in the current device (TV/browser) remotely.
 */
export function QrSignInPanel({ onGoogleSignIn, onPinSignIn, oauthConfigured }: QrSignInPanelProps) {
  const { session, secondsLeft, loading } = useQrSession();
  const canvasRef = useRef<HTMLCanvasElement>(null);

  // Render QR code to canvas whenever the session QR URL changes
  useEffect(() => {
    if (!session?.qr_url || !canvasRef.current) return;

    // Dynamic import so qrcode is only loaded when this panel is shown
    import('qrcode').then((QRCode: typeof import('qrcode')) => {
      QRCode.toCanvas(canvasRef.current!, session.qr_url, {
        width: 0, // responsive — fill the canvas element's CSS size
        margin: 1,
        color: {
          dark: '#ffffff',
          light: '#00000000', // transparent background so glass shows through
        },
        errorCorrectionLevel: 'M',
      }).catch(() => {
        // Silently ignore — the manual code is always the fallback
      });
    }).catch(() => { /* qrcode pkg not available */ });
  }, [session?.qr_url]);

  // Progress percentage for the countdown arc
  const pct = Math.min(100, Math.max(0, (secondsLeft / 120) * 100));
  const RADIUS = 10;
  const CIRCUM = 2 * Math.PI * RADIUS;
  const dash = (pct / 100) * CIRCUM;

  // Extract just the hostname path for display (strip https://)
  const loginUrlDisplay = session?.login_url
    ? session.login_url.replace(/^https?:\/\//, '')
    : 'media.anisparvez.in/remotelogin';

  return (
    <div className="space-y-6">
      {/* QR + Instructions grid */}
      <div className="flex flex-col sm:flex-row gap-5 items-start">
        {/* QR Code card */}
        <div className="flex-shrink-0 flex flex-col items-center gap-3">
          <div
            className="relative flex items-center justify-center rounded-2xl bg-white/5 border border-white/10 overflow-hidden"
            style={{ width: 'clamp(160px, 22vw, 220px)', height: 'clamp(160px, 22vw, 220px)' }}
          >
            {loading ? (
              <div className="h-8 w-8 rounded-full border-2 border-white/10 border-t-brand-500 animate-spin" />
            ) : (
              <canvas
                ref={canvasRef}
                className="w-full h-full object-contain"
                aria-label="QR code to sign in on this device"
              />
            )}
          </div>

          {/* Pair code + countdown */}
          <div className="flex items-center gap-3">
            <div className="text-center">
              <p className="text-[10px] font-semibold tracking-widest text-white/40 uppercase mb-1">
                Code
              </p>
              <p className="font-mono text-2xl font-bold tracking-[0.25em] text-white select-all">
                {loading ? '·····' : (session?.code ?? '·····')}
              </p>
            </div>

            {/* SVG countdown ring */}
            <div
              className="relative flex items-center justify-center"
              title={`Refreshes in ${formatCountdown(secondsLeft)}`}
              aria-label={`Code refreshes in ${formatCountdown(secondsLeft)}`}
            >
              <svg width="36" height="36" viewBox="0 0 28 28" aria-hidden="true">
                {/* Track */}
                <circle
                  cx="14" cy="14" r={RADIUS}
                  fill="none" strokeWidth="2.5"
                  stroke="rgba(255,255,255,0.08)"
                />
                {/* Progress arc */}
                <circle
                  cx="14" cy="14" r={RADIUS}
                  fill="none" strokeWidth="2.5"
                  stroke={secondsLeft <= 15 ? '#f97316' : '#e50914'}
                  strokeLinecap="round"
                  strokeDasharray={`${dash} ${CIRCUM}`}
                  transform="rotate(-90 14 14)"
                  className="transition-all duration-1000"
                />
              </svg>
              <span className="absolute text-[9px] font-bold text-white/70 tabular-nums">
                {formatCountdown(secondsLeft)}
              </span>
            </div>
          </div>
        </div>

        {/* Instructions */}
        <div className="flex-1 min-w-0 space-y-4 pt-1">
          <div>
            <p className="text-sm font-semibold text-white/90 mb-1">
              Sign in from your phone
            </p>
            <p className="text-xs text-white/55 leading-relaxed">
              Open the link on your phone or tablet. You'll sign in there and this
              browser will automatically become signed in.
            </p>
          </div>

          {/* Manual URL box */}
          <div className="rounded-xl border border-white/10 bg-white/[0.04] px-4 py-3 space-y-1.5">
            <p className="text-[10px] font-semibold tracking-widest text-white/40 uppercase">
              Visit on your phone
            </p>
            <p className="font-mono text-sm font-medium text-brand-300 break-all select-all">
              {loginUrlDisplay}
            </p>
            <p className="text-[11px] text-white/40">
              Then enter code{' '}
              <span className="font-mono font-bold text-white/70">
                {loading ? '·····' : (session?.code ?? '·····')}
              </span>
            </p>
          </div>

          {/* Scan hint */}
          <div className="flex items-start gap-2.5 rounded-xl border border-brand-500/20 bg-brand-500/5 px-3.5 py-2.5">
            <span className="text-brand-400 text-base shrink-0 mt-0.5" aria-hidden="true">📱</span>
            <p className="text-xs text-white/60 leading-relaxed">
              Or just <strong className="text-white/80">scan the QR code</strong> with your
              phone's camera — the code will be filled in automatically.
            </p>
          </div>
        </div>
      </div>

      {/* Divider */}
      <div className="flex items-center gap-3">
        <div className="flex-1 h-px bg-white/10" />
        <span className="text-[11px] font-medium text-white/35 tracking-wider">
          OR SIGN IN ON THIS DEVICE
        </span>
        <div className="flex-1 h-px bg-white/10" />
      </div>

      {/* Direct sign-in buttons */}
      <div className="flex flex-wrap gap-3">
        {oauthConfigured && (
          <button
            type="button"
            id="qr-panel-google-signin"
            onClick={onGoogleSignIn}
            className="card-ring brand-gradient brand-glow-sm rounded-full px-5 py-2.5 text-sm font-semibold text-white shadow-md transition hover:scale-105 active:scale-95"
          >
            Sign in with Google →
          </button>
        )}
        <button
          type="button"
          id="qr-panel-pin-signin"
          onClick={onPinSignIn}
          className="rounded-full border border-white/15 bg-white/5 px-5 py-2.5 text-sm font-semibold text-white/80 transition hover:border-white/30 hover:bg-white/10 hover:text-white active:scale-95"
        >
          Admin PIN
        </button>
      </div>
    </div>
  );
}
