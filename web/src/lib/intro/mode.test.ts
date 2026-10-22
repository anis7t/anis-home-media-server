import { describe, expect, it } from 'vitest';

import { DEFAULT_INTRO_MODE, INTRO_MODES, parseIntroMode } from './mode';

/**
 * The `?intro=` mode parser.
 *
 * Mirrors the archived original's own rule (source 916-917): the parameter is
 * matched with `/[?&]intro=([a-z]+)/`, and anything that is not one of the
 * known modes falls back to `auto`.
 */
describe('parseIntroMode', () => {
  it('defaults to auto when there is no parameter', () => {
    expect(parseIntroMode('')).toBe('auto');
    expect(parseIntroMode('?other=1')).toBe('auto');
    expect(DEFAULT_INTRO_MODE).toBe('auto');
  });

  it('reads each known mode', () => {
    for (const mode of INTRO_MODES) {
      expect(parseIntroMode(`?intro=${mode}`)).toBe(mode);
    }
  });

  it('falls back to auto for an unrecognised mode', () => {
    expect(parseIntroMode('?intro=nonsense')).toBe('auto');
    expect(parseIntroMode('?intro=replay')).toBe('auto');
    expect(parseIntroMode('?intro=')).toBe('auto');
  });

  it('only matches a lower-case word, as the original did', () => {
    // The original's regex is `/[?&]intro=([a-z]+)/`, so an upper-case value
    // does not match at all, and a trailing non-letter is simply not part of
    // the match. Both are reproduced rather than "improved".
    expect(parseIntroMode('?intro=GATE')).toBe('auto');
    expect(parseIntroMode('?intro=gate2')).toBe('gate');
  });

  it('finds the parameter among others', () => {
    expect(parseIntroMode('?a=1&intro=gate&b=2')).toBe('gate');
    expect(parseIntroMode('#x?intro=capture')).toBe('capture');
  });
});
