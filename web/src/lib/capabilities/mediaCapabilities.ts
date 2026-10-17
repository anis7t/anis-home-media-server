/**
 * Client Media Capability Probing Utility.
 *
 * Implements dynamic, client-side codec and container capability checks using:
 * 1. HTMLMediaElement.canPlayType()
 * 2. W3C Media Capabilities API (navigator.mediaCapabilities.decodingInfo())
 *
 * Prevents layman users from encountering silent playback deadlocks when attempting
 * to direct-play unsupported containers (.mkv) or proprietary audio (E-AC-3 / Dolby Digital Plus)
 * on web browsers that lack native demuxers or software decoders.
 */

export interface CapabilityVerdict {
  canDirectPlay: boolean;
  reason?: string;
  smooth?: boolean;
  powerEfficient?: boolean;
}

/**
 * Standardize codec strings to standard MIME parameter formats for browser probing.
 */
export function normalizeVideoCodecMime(
  container: string,
  videoCodec?: string,
  width?: number | null,
  height?: number | null,
): string {
  const c = container.toLowerCase();
  const v = (videoCodec || '').toLowerCase();
  const is4K = (width != null && width >= 3840) || (height != null && height >= 2160);

  const baseMime = c === 'mkv' ? 'video/x-matroska' : c === 'webm' ? 'video/webm' : 'video/mp4';

  if (v.includes('hevc') || v.includes('h265') || v.includes('h.265')) {
    // Level 5.0 for 4K UHD (Main 10 Profile), Level 4.0 for 1080p
    return is4K
      ? `${baseMime}; codecs="hvc1.1.6.L150.90"`
      : `${baseMime}; codecs="hvc1.1.6.L120.90"`;
  }
  if (v.includes('h264') || v.includes('avc') || v.includes('h.264')) {
    // High Profile H.264: Level 5.1 for 4K, Level 4.0 for 1080p
    return is4K
      ? `${baseMime}; codecs="avc1.640033"`
      : `${baseMime}; codecs="avc1.640028"`;
  }
  if (v.includes('vp9')) {
    return is4K
      ? 'video/webm; codecs="vp09.00.50.10"'
      : 'video/webm; codecs="vp09.00.10.08"';
  }
  if (v.includes('av1')) {
    return is4K
      ? `${baseMime}; codecs="av01.0.12M.10"`
      : `${baseMime}; codecs="av01.0.08M.08"`;
  }

  return baseMime;
}

function normalizeAudioCodecMime(container: string, audioCodec?: string): string {
  const c = container.toLowerCase();
  const a = (audioCodec || '').toLowerCase();

  const baseMime = c === 'mkv' ? 'audio/x-matroska' : c === 'webm' ? 'audio/webm' : 'audio/mp4';

  if (a.includes('eac3') || a.includes('ec-3') || a.includes('ddp') || a.includes('dolby digital plus')) {
    return `${baseMime}; codecs="ec-3"`;
  }
  if (a.includes('ac3') || a.includes('ac-3') || a.includes('dolby')) {
    return `${baseMime}; codecs="ac-3"`;
  }
  if (a.includes('aac')) {
    return `${baseMime}; codecs="mp4a.40.2"`;
  }
  if (a.includes('opus')) {
    return 'audio/webm; codecs="opus"';
  }
  if (a.includes('flac')) {
    return `${baseMime}; codecs="flac"`;
  }

  return baseMime;
}

/**
 * In-memory cache of evaluated capability verdicts keyed by container + codecs + resolution.
 */
const verdictCache = new Map<string, CapabilityVerdict>();

export function clearVerdictCache(): void {
  verdictCache.clear();
}

export interface MediaProbeOptions {
  width?: number | null;
  height?: number | null;
  bitrate?: number | null;
  framerate?: number | null;
}

/**
 * Probe the browser's exact capability to direct-play a specific container, video codec, audio codec, and resolution.
 */
export async function probeClientMediaCapabilities(
  container: string,
  videoCodec?: string,
  audioCodec?: string,
  options?: MediaProbeOptions,
): Promise<CapabilityVerdict> {
  const normContainer = (container || '').toLowerCase().replace(/^\./, '');
  const normVideo = (videoCodec || '').toLowerCase();
  const normAudio = (audioCodec || '').toLowerCase();

  const is4K = (options?.width != null && options.width >= 3840) ||
               (options?.height != null && options.height >= 2160);
  const probeWidth = options?.width ?? (is4K ? 3840 : 1920);
  const probeHeight = options?.height ?? (is4K ? 2160 : 1080);
  const probeBitrate = options?.bitrate ?? (is4K ? 25_000_000 : 5_000_000);
  const probeFramerate = options?.framerate ?? 30;

  const cacheKey = `${normContainer}:${normVideo}:${normAudio}:${probeWidth}x${probeHeight}`;
  if (verdictCache.has(cacheKey)) {
    return verdictCache.get(cacheKey)!;
  }

  // 1. Check container demuxing capability via canPlayType
  if (typeof document !== 'undefined') {
    const videoTest = document.createElement('video');
    const containerMime =
      normContainer === 'mkv'
        ? 'video/x-matroska'
        : normContainer === 'webm'
          ? 'video/webm'
          : 'video/mp4';

    const containerSupport = videoTest.canPlayType(containerMime);
    if (!containerSupport && normContainer === 'mkv') {
      const verdict: CapabilityVerdict = {
        canDirectPlay: false,
        reason: 'Matroska (.mkv) container cannot be decoded natively by this web browser',
      };
      verdictCache.set(cacheKey, verdict);
      return verdict;
    }

    // 2. Check audio codec support (e.g. EAC-3 / Dolby Digital Plus)
    if (normAudio.includes('eac3') || normAudio.includes('ec-3') || normAudio.includes('ddp')) {
      const audioSupport =
        videoTest.canPlayType('audio/mp4; codecs="ec-3"') ||
        videoTest.canPlayType('audio/x-matroska; codecs="ec-3"');
      if (!audioSupport) {
        const verdict: CapabilityVerdict = {
          canDirectPlay: false,
          reason: 'Dolby Digital Plus (E-AC-3) audio is unsupported by this browser',
        };
        verdictCache.set(cacheKey, verdict);
        return verdict;
      }
    }
  }

  // 3. W3C Media Capabilities API probe
  if (
    typeof navigator !== 'undefined' &&
    navigator.mediaCapabilities &&
    typeof navigator.mediaCapabilities.decodingInfo === 'function'
  ) {
    try {
      const videoContentType = normalizeVideoCodecMime(normContainer, normVideo, probeWidth, probeHeight);
      const audioContentType = normalizeAudioCodecMime(normContainer, normAudio);

      let result = await navigator.mediaCapabilities.decodingInfo({
        type: 'file',
        video: {
          contentType: videoContentType,
          width: probeWidth,
          height: probeHeight,
          bitrate: probeBitrate,
          framerate: probeFramerate,
        },
        audio: {
          contentType: audioContentType,
          bitrate: 384_000,
          samplerate: 48000,
          channels: '6',
        },
      });

      // If hvc1 parameter tag was rejected, probe alternate hev1 tag
      if (!result.supported && videoContentType.includes('hvc1')) {
        const altContentType = videoContentType.replace('hvc1', 'hev1');
        try {
          const altResult = await navigator.mediaCapabilities.decodingInfo({
            type: 'file',
            video: {
              contentType: altContentType,
              width: probeWidth,
              height: probeHeight,
              bitrate: probeBitrate,
              framerate: probeFramerate,
            },
            audio: {
              contentType: audioContentType,
              bitrate: 384_000,
              samplerate: 48000,
              channels: '6',
            },
          });
          if (altResult.supported) {
            result = altResult;
          }
        } catch {}
      }

      if (!result.supported) {
        const verdict: CapabilityVerdict = {
          canDirectPlay: false,
          reason: `Browser decoders do not support ${normVideo.toUpperCase() || 'video'} or ${normAudio.toUpperCase() || 'audio'} in .${normContainer}`,
          smooth: result.smooth,
          powerEfficient: result.powerEfficient,
        };
        verdictCache.set(cacheKey, verdict);
        return verdict;
      }

      const verdict: CapabilityVerdict = {
        canDirectPlay: true,
        smooth: result.smooth,
        powerEfficient: result.powerEfficient,
      };
      verdictCache.set(cacheKey, verdict);
      return verdict;
    } catch {
      // Fallback if decodingInfo throws for unknown MIME strings
    }
  }

  // 4. Default evaluation: MP4/WebM with standard codecs is accepted; MKV defaults to false on Web
  const isDirectContainer = ['mp4', 'm4v', 'webm'].includes(normContainer);
  const isEAC3 = normAudio.includes('eac3') || normAudio.includes('ec-3');

  if (normContainer === 'mkv') {
    const verdict: CapabilityVerdict = {
      canDirectPlay: false,
      reason: 'Matroska (.mkv) container cannot be decoded natively by this web browser',
    };
    verdictCache.set(cacheKey, verdict);
    return verdict;
  }

  if (isEAC3) {
    const verdict: CapabilityVerdict = {
      canDirectPlay: false,
      reason: 'Dolby Digital Plus (E-AC-3) audio is unsupported by this browser',
    };
    verdictCache.set(cacheKey, verdict);
    return verdict;
  }

  const verdict: CapabilityVerdict = {
    canDirectPlay: isDirectContainer,
    reason: isDirectContainer ? undefined : `.${normContainer} requires adaptive streaming`,
  };
  verdictCache.set(cacheKey, verdict);
  return verdict;
}
