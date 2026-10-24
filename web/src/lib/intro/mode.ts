/**
 * The intro's modes.
 *
 * Parsed from the `?intro=` query parameter, exactly as the archived original
 * did (`docs/opening-sequence/source/intro-overlay.html`, source 916-917):
 * the parameter is matched with `/[?&]intro=([a-z]+)/`, and **anything that
 * is not one of the four known modes falls back to `auto`**.
 */

export type IntroMode = 'auto' | 'gate' | 'capture' | 'off';

export const INTRO_MODES: readonly IntroMode[] = ['auto', 'gate', 'capture', 'off'];

/** The default when there is no `?intro=` parameter, or it is not recognised. */
export const DEFAULT_INTRO_MODE: IntroMode = 'auto';

export const parseIntroMode = (search: string): IntroMode => {
  const match = /[?&]intro=([a-z]+)/.exec(search ?? '');
  const value = match?.[1] as IntroMode | undefined;
  return value && INTRO_MODES.includes(value) ? value : DEFAULT_INTRO_MODE;
};

/** The key the session gate is stored under (source 974). */
export const INTRO_SEEN_KEY = 'introSeen';
