import { useEffect, useRef, useState, useCallback, type RefObject } from 'react';

export interface SubtitleTrack {
  id?: string;
  name?: string;
  label: string;
  lang: string;
  src: string;
  default?: boolean;
}

export interface SubtitlePrefs {
  enabled: boolean;
  trackIndex: number;
  color: string;
  bgOpacity: string;
  size: string;
  align: 'center' | 'left' | 'right';
  pos: number;
  verticalPos: 'lowered' | 'bottom' | 'raised' | 'middle' | 'top';
  offset: number;
}

const SUB_KEY = 'media_sub_settings';
export const DEFAULT_SUB_SIZE = 'clamp(22px, 2.8vw, 36px)';

export const SUB_SIZE_MAP: Record<string, string> = {
  '75%': 'clamp(17px, 2.1vw, 27px)',
  '100%': 'clamp(22px, 2.8vw, 36px)',
  '125%': 'clamp(28px, 3.5vw, 45px)',
  '150%': 'clamp(33px, 4.2vw, 54px)',
  '200%': 'clamp(44px, 5.6vw, 72px)',
};

const DEFAULT_PREFS: SubtitlePrefs = {
  enabled: true,
  trackIndex: -1,
  color: '#ffffff',
  bgOpacity: '0.75',
  size: DEFAULT_SUB_SIZE,
  align: 'center',
  pos: 50,
  verticalPos: 'lowered',
  offset: 0,
};

function loadSavedPrefs(): SubtitlePrefs {
  try {
    const saved = localStorage.getItem(SUB_KEY);
    if (!saved) return DEFAULT_PREFS;
    const parsed = JSON.parse(saved);
    const prefs: SubtitlePrefs = { ...DEFAULT_PREFS, ...parsed };

    if (prefs.size && SUB_SIZE_MAP[prefs.size]) {
      prefs.size = SUB_SIZE_MAP[prefs.size];
    } else if (!prefs.size || !prefs.size.includes('clamp')) {
      prefs.size = DEFAULT_SUB_SIZE;
    }
    if (!prefs.align) prefs.align = 'center';
    if (prefs.pos == null) prefs.pos = 50;
    if (!prefs.verticalPos || (prefs.verticalPos as string) === 'bottom') {
      prefs.verticalPos = 'lowered';
    }
    if (typeof prefs.offset !== 'number' || isNaN(prefs.offset)) {
      prefs.offset = 0;
    }
    return prefs;
  } catch {
    return DEFAULT_PREFS;
  }
}

function savePrefs(prefs: SubtitlePrefs) {
  try {
    localStorage.setItem(SUB_KEY, JSON.stringify(prefs));
  } catch {}
}

export function applySubStyles(prefs: SubtitlePrefs) {
  let sEl = document.getElementById('cue-styles') as HTMLStyleElement | null;
  if (!sEl) {
    sEl = document.createElement('style');
    sEl.id = 'cue-styles';
    document.head.appendChild(sEl);
  }
  const bg = `rgba(0, 0, 0, ${prefs.bgOpacity})`;
  const align = prefs.align || 'center';
  sEl.textContent = `video::cue {
  color: ${prefs.color} !important;
  background-color: ${bg} !important;
  font-size: ${prefs.size} !important;
  font-family: system-ui, -apple-system, sans-serif !important;
  text-shadow: 0 1px 2px #000, 0 0 3px #000 !important;
  line-height: 1.3 !important;
  text-align: ${align} !important;
}`;
}

export function elevateCues(video: HTMLVideoElement | null, prefs: SubtitlePrefs) {
  if (!video) return;
  const trks = Array.from(video.textTracks);
  const isHuge =
    prefs.size && (prefs.size.includes('44px') || prefs.size.includes('33px'));
  const vPos = prefs.verticalPos || 'lowered';
  const isMob = typeof window !== 'undefined' && window.innerWidth <= 768;

  let targetLine = isMob ? (isHuge ? -5.8 : -5.0) : (isHuge ? -4.8 : -4.0);
  let snap = true;

  if (vPos === 'lowered') {
    targetLine = isMob ? (isHuge ? -3.8 : -3.2) : (isHuge ? -2.8 : -2.2);
  } else if (vPos === 'raised') {
    targetLine = isMob ? (isHuge ? -7.2 : -6.5) : (isHuge ? -6.2 : -5.5);
  } else if (vPos === 'middle') {
    snap = false;
    targetLine = 50;
  } else if (vPos === 'top') {
    targetLine = 2;
  }

  const targetAlign = prefs.align || 'center';
  const targetPos = prefs.pos ?? 50;
  const offset = prefs.offset || 0;

  const applyCueStyles = (c: VTTCue) => {
    c.snapToLines = snap;
    c.line = targetLine;
    try {
      c.align = targetAlign;
    } catch {}
    try {
      c.position = targetPos;
    } catch {}

    // Apply subtitle timing offset dynamically
    if ((c as any)._origStartTime === undefined) {
      (c as any)._origStartTime = c.startTime;
      (c as any)._origEndTime = c.endTime;
    }
    const origStart = (c as any)._origStartTime;
    const origEnd = (c as any)._origEndTime;
    const dur = Math.max(0.1, origEnd - origStart);
    const newStart = Math.max(0, origStart + offset);
    c.startTime = newStart;
    c.endTime = newStart + dur;
  };

  trks.forEach((t) => {
    if (t.cues) {
      for (let i = 0; i < t.cues.length; i++) {
        applyCueStyles(t.cues[i] as VTTCue);
      }
    }

    if (!(t as any)._cueElevated) {
      (t as any)._cueElevated = true;
      t.addEventListener('cuechange', () => {
        if (t.activeCues) {
          for (let i = 0; i < t.activeCues.length; i++) {
            applyCueStyles(t.activeCues[i] as VTTCue);
          }
        }
      });
    }
  });
}

function findEnglishTrack(trks: SubtitleTrack[]): number {
  if (!trks || !trks.length) return -1;
  const isEn = (lang?: string, lbl?: string) => {
    const l = (lang || '').toLowerCase().trim();
    const b = (lbl || '').toLowerCase().trim();
    return (
      l === 'en' ||
      l === 'eng' ||
      l.startsWith('en-') ||
      l.startsWith('en_') ||
      b.includes('english') ||
      b.includes('(eng)') ||
      b.includes('[eng]') ||
      b.includes(' - eng') ||
      b.startsWith('eng ')
    );
  };
  const idx = trks.findIndex((t) => isEn(t.lang, t.label));
  if (idx >= 0) return idx;
  const defIdx = trks.findIndex((t) => t.default);
  return defIdx >= 0 ? defIdx : -1;
}

export function useSubtitles(
  videoRef: RefObject<HTMLVideoElement | null>,
  filename: string,
  onShowHud?: (msg: string) => void
) {
  const [tracks, setTracks] = useState<SubtitleTrack[]>([]);
  const [activeTrackIndex, setActiveTrackIndex] = useState<number>(-1);
  const [prefs, setPrefs] = useState<SubtitlePrefs>(loadSavedPrefs);
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [isUploading, setIsUploading] = useState(false);
  const initializedRef = useRef(false);

  // Sync styles on mount and prefs change
  useEffect(() => {
    applySubStyles(prefs);
    elevateCues(videoRef.current, prefs);
    savePrefs(prefs);
  }, [prefs, videoRef]);

  // Synchronize textTracks modes whenever tracks or activeTrackIndex changes
  const syncTrackModes = useCallback(
    (index: number) => {
      const video = videoRef.current;
      if (!video) return;
      Array.from(video.textTracks).forEach((t, i) => {
        t.mode = i === index ? 'showing' : 'disabled';
      });
      elevateCues(video, prefs);
    },
    [videoRef, prefs]
  );

  const selectTrack = useCallback(
    (idx: number, showFeedback = true) => {
      const index = Number(idx);
      setActiveTrackIndex(index);
      setPrefs((prev) => {
        const next = { ...prev, trackIndex: index, enabled: index >= 0 };
        savePrefs(next);
        return next;
      });

      syncTrackModes(index);

      if (showFeedback && onShowHud) {
        if (index < 0) {
          onShowHud('Subtitles Off');
        } else if (tracks[index]) {
          onShowHud(`💬 ${tracks[index].label}`);
        } else {
          onShowHud('CC On');
        }
      }
    },
    [syncTrackModes, onShowHud, tracks]
  );

  const toggleCC = useCallback(() => {
    if (!tracks.length) return;
    if (activeTrackIndex >= 0) {
      selectTrack(-1);
    } else {
      let target = findEnglishTrack(tracks);
      if (target < 0) {
        target =
          prefs.trackIndex >= 0 && prefs.trackIndex < tracks.length
            ? prefs.trackIndex
            : 0;
      }
      selectTrack(target);
    }
  }, [tracks, activeTrackIndex, prefs.trackIndex, selectTrack]);

  const updatePref = useCallback(
    <K extends keyof SubtitlePrefs>(key: K, value: SubtitlePrefs[K]) => {
      setPrefs((prev) => {
        const next = { ...prev, [key]: value };
        savePrefs(next);
        return next;
      });
    },
    []
  );

  // Fetch track list
  const refreshTracks = useCallback(
    async (preferTrackName?: string, signal?: AbortSignal) => {
      if (!filename) return;
      const encoded = filename.split('/').map(encodeURIComponent).join('/');
      try {
        const res = await fetch(`/api/subtitles/${encoded}`, { signal });
        if (!res.ok) return;
        const data = await res.json();
        const trks: SubtitleTrack[] = Array.isArray(data.tracks) ? data.tracks : [];
        setTracks(trks);

        if (trks.length > 0) {
          if (preferTrackName) {
            const idx = trks.findIndex(
              (t) =>
                t.name === preferTrackName ||
                (t.id && t.id.includes(preferTrackName))
            );
            if (idx >= 0) {
              selectTrack(idx);
              return;
            }
          }

          if (!initializedRef.current) {
            initializedRef.current = true;
            const engIdx = findEnglishTrack(trks);
            let initIdx = -1;
            if (engIdx >= 0) {
              initIdx = engIdx;
            } else if (
              prefs.enabled &&
              prefs.trackIndex >= 0 &&
              prefs.trackIndex < trks.length
            ) {
              initIdx = prefs.trackIndex;
            } else if (prefs.enabled) {
              initIdx = 0;
            }
            selectTrack(initIdx, false);
          }
        }
      } catch (err: any) {
        if (err.name === 'AbortError') return;
        // Silent in test or non-critical environments
      }
    },
    [filename, prefs.enabled, prefs.trackIndex, selectTrack]
  );

  useEffect(() => {
    const controller = new AbortController();
    initializedRef.current = false;
    void refreshTracks(undefined, controller.signal);
    return () => controller.abort();
  }, [filename, refreshTracks]);

  // Handle subtitle upload
  const uploadSubtitle = useCallback(
    async (file: File): Promise<{ success: boolean; message: string; filename?: string }> => {
      setIsUploading(true);
      const fd = new FormData();
      fd.append('subtitle', file);
      const encoded = filename.split('/').map(encodeURIComponent).join('/');
      try {
        const res = await fetch(`/api/upload-subtitle/${encoded}`, {
          method: 'POST',
          body: fd,
        });
        const data = await res.json();
        if (data.success) {
          const langMap: Record<string, string> = {
            en: 'English',
            hi: 'Hindi',
            es: 'Spanish',
            fr: 'French',
            de: 'German',
            it: 'Italian',
            pt: 'Portuguese',
            ru: 'Russian',
            ja: 'Japanese',
            zh: 'Chinese',
            ko: 'Korean',
            ar: 'Arabic',
            bn: 'Bengali',
          };
          const langLabel =
            langMap[data.language] ||
            (data.language === 'und' ? 'Unknown' : data.language.toUpperCase());
          await refreshTracks(data.filename);
          return {
            success: true,
            message: `Uploaded: ${data.filename} (${langLabel})`,
            filename: data.filename,
          };
        } else {
          return {
            success: false,
            message: data.error || 'Upload failed.',
          };
        }
      } catch {
        return {
          success: false,
          message: 'Network error. Please try again.',
        };
      } finally {
        setIsUploading(false);
      }
    },
    [filename, refreshTracks]
  );

  const adjustOffset = useCallback(
    (delta: number) => {
      setPrefs((prev) => {
        const nextOffset = Math.round(((prev.offset || 0) + delta) * 10) / 10;
        const clamped = Math.max(-5, Math.min(5, nextOffset));
        const next = { ...prev, offset: clamped };
        savePrefs(next);
        if (onShowHud) {
          const sign = clamped > 0 ? `+${clamped.toFixed(1)}s` : `${clamped.toFixed(1)}s`;
          const status = clamped > 0 ? ' (Delayed)' : clamped < 0 ? ' (Advanced)' : ' (In Sync)';
          onShowHud(`💬 Subtitle Sync: ${sign}${status}`);
        }
        return next;
      });
    },
    [onShowHud]
  );

  return {
    tracks,
    activeTrackIndex,
    prefs,
    isSettingsOpen,
    isUploading,
    setIsSettingsOpen,
    selectTrack,
    toggleCC,
    updatePref,
    adjustOffset,
    uploadSubtitle,
    elevateCues: () => elevateCues(videoRef.current, prefs),
  };
}
