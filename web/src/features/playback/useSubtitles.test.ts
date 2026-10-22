import { renderHook, act } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  applyCueLayout,
  applyCueTiming,
  applySubStyles,
  elevateCues,
  useSubtitles,
  DEFAULT_SUB_SIZE,
  type SubtitlePrefs,
} from './useSubtitles';

// Mock VTTCue for jsdom environment if not defined
class MockVTTCue {
  startTime: number;
  endTime: number;
  text: string;
  snapToLines = true;
  line: number | 'auto' = 'auto';
  align: 'start' | 'center' | 'end' | 'left' | 'right' = 'center';
  position: number | 'auto' = 'auto';

  constructor(startTime: number, endTime: number, text: string) {
    this.startTime = startTime;
    this.endTime = endTime;
    this.text = text;
  }
}

if (typeof (globalThis as any).VTTCue === 'undefined') {
  (globalThis as any).VTTCue = MockVTTCue;
}

describe('useSubtitles helpers & flicker-free offset logic', () => {
  beforeEach(() => {
    const sEl = document.getElementById('cue-styles');
    if (sEl) sEl.remove();
    vi.clearAllMocks();
  });

  it('applySubStyles creates cue-styles in document.head and is idempotent', () => {
    const prefs: SubtitlePrefs = {
      enabled: true,
      trackIndex: 0,
      color: '#00ff66',
      bgOpacity: '0.5',
      size: DEFAULT_SUB_SIZE,
      align: 'center',
      pos: 50,
      verticalPos: 'lowered',
      offset: 0,
    };

    applySubStyles(prefs);
    const styleEl = document.getElementById('cue-styles') as HTMLStyleElement;
    expect(styleEl).toBeInTheDocument();
    expect(styleEl.textContent).toContain('color: #00ff66 !important;');
    expect(styleEl.textContent).toContain('background-color: rgba(0, 0, 0, 0.5) !important;');

    // Spy on setter to verify idempotency
    let setterCalled = false;
    const originalDesc = Object.getOwnPropertyDescriptor(Node.prototype, 'textContent');
    if (originalDesc?.set) {
      const origSet = originalDesc.set;
      vi.spyOn(styleEl, 'textContent', 'set').mockImplementation(function (this: HTMLStyleElement, val: string) {
        setterCalled = true;
        origSet.call(this, val);
      });
    }

    // Call again with same styles: should NOT touch textContent
    applySubStyles({ ...prefs, offset: 0.5 });
    expect(setterCalled).toBe(false);
  });

  it('applyCueTiming preserves duration and applies timing offset without changing cue identity', () => {
    const cue = new MockVTTCue(10.0, 14.0, 'Hello World') as unknown as VTTCue;

    // Shift +250ms
    applyCueTiming(cue, 0.25);
    expect(cue.startTime).toBeCloseTo(10.25, 3);
    expect(cue.endTime).toBeCloseTo(14.25, 3);
    expect(cue.endTime - cue.startTime).toBeCloseTo(4.0, 3);

    // Shift -500ms from original
    applyCueTiming(cue, -0.5);
    expect(cue.startTime).toBeCloseTo(9.5, 3);
    expect(cue.endTime).toBeCloseTo(13.5, 3);

    // Clamps start at 0
    applyCueTiming(cue, -15.0);
    expect(cue.startTime).toBe(0);
    expect(cue.endTime).toBeCloseTo(4.0, 3);
  });

  it('applyCueLayout applies positioning and guards against redundant writes', () => {
    const cue = new MockVTTCue(0, 5, 'Subtitle Text') as unknown as VTTCue;
    applyCueLayout(cue, true, -3.2, 'center', 50);

    expect(cue.snapToLines).toBe(true);
    expect(cue.line).toBe(-3.2);
    expect(cue.align).toBe('center');
    expect(cue.position).toBe(50);
  });

  it('elevateCues iterates cues and applies both layout and timing', () => {
    const cue1 = new MockVTTCue(1.0, 3.0, 'One') as unknown as VTTCue;
    const cue2 = new MockVTTCue(4.0, 6.0, 'Two') as unknown as VTTCue;

    const mockTrack = {
      cues: [cue1, cue2],
      activeCues: [],
      addEventListener: vi.fn(),
    };

    const mockVideo = {
      textTracks: [mockTrack],
    } as unknown as HTMLVideoElement;

    const prefs: SubtitlePrefs = {
      enabled: true,
      trackIndex: 0,
      color: '#ffffff',
      bgOpacity: '0.75',
      size: DEFAULT_SUB_SIZE,
      align: 'center',
      pos: 50,
      verticalPos: 'lowered',
      offset: 0.1,
    };

    elevateCues(mockVideo, prefs);

    expect(cue1.startTime).toBeCloseTo(1.1, 3);
    expect(cue1.endTime).toBeCloseTo(3.1, 3);
    expect(cue2.startTime).toBeCloseTo(4.1, 3);
    expect(cue2.endTime).toBeCloseTo(6.1, 3);
    expect(mockTrack.addEventListener).toHaveBeenCalledWith('cuechange', expect.any(Function));
  });

  it('useSubtitles adjustOffset modifies offset, clamps bounds, and triggers HUD message', () => {
    const mockVideoRef = { current: null };
    const hudMessages: string[] = [];
    const showHud = (msg: string) => hudMessages.push(msg);

    const { result } = renderHook(() =>
      useSubtitles(mockVideoRef, 'sample_movie.mp4', showHud)
    );

    // Initial offset should be 0
    expect(result.current.prefs.offset).toBe(0);

    // Adjust by +0.05
    act(() => {
      const next = result.current.adjustOffset(0.05);
      expect(next).toBe(0.05);
    });
    expect(result.current.prefs.offset).toBe(0.05);
    expect(hudMessages[hudMessages.length - 1]).toContain('+0.05s (+50ms) (Delayed)');

    // Adjust by -0.10
    act(() => {
      const next = result.current.adjustOffset(-0.1);
      expect(next).toBe(-0.05);
    });
    expect(result.current.prefs.offset).toBe(-0.05);
    expect(hudMessages[hudMessages.length - 1]).toContain('-0.05s (-50ms) (Advanced)');

    // Bounds clamping test (+10s -> clamped to +5s)
    act(() => {
      const next = result.current.adjustOffset(10);
      expect(next).toBe(5);
    });
    expect(result.current.prefs.offset).toBe(5);

    // Bounds clamping test (-10s -> clamped to -5s)
    act(() => {
      const next = result.current.adjustOffset(-15);
      expect(next).toBe(-5);
    });
    expect(result.current.prefs.offset).toBe(-5);
  });
});
