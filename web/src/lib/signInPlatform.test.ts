import { describe, expect, it } from 'vitest';

import { isPhoneBrowser } from './signInPlatform';

const IPHONE_UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const ANDROID_PHONE_UA =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
const ANDROID_TABLET_UA =
  'Mozilla/5.0 (Linux; Android 14; SM-X710) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const IPAD_UA =
  'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const DESKTOP_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const TV_UA =
  'Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.128 Safari/537.36';

describe('isPhoneBrowser', () => {
  it('detects iPhone and Android phone user agents', () => {
    expect(isPhoneBrowser({ userAgent: IPHONE_UA })).toBe(true);
    expect(isPhoneBrowser({ userAgent: ANDROID_PHONE_UA })).toBe(true);
  });

  it('does not treat tablets, desktops or TV browsers as phones', () => {
    expect(isPhoneBrowser({ userAgent: IPAD_UA })).toBe(false);
    expect(isPhoneBrowser({ userAgent: ANDROID_TABLET_UA })).toBe(false);
    expect(isPhoneBrowser({ userAgent: DESKTOP_UA })).toBe(false);
    expect(isPhoneBrowser({ userAgent: TV_UA })).toBe(false);
  });

  it('trusts the Chromium client hint when it says mobile', () => {
    expect(
      isPhoneBrowser({
        userAgent: DESKTOP_UA,
        userAgentData: { mobile: true },
      }),
    ).toBe(true);
  });

  it('uses a phone-sized coarse pointer as a last-resort fallback', () => {
    expect(
      isPhoneBrowser({ userAgent: 'Unrecognised', viewportWidth: 390, coarsePointer: true }),
    ).toBe(true);
    expect(
      isPhoneBrowser({ userAgent: 'Unrecognised', viewportWidth: 1024, coarsePointer: true }),
    ).toBe(false);
  });

  it('fails open when there is no platform information', () => {
    expect(isPhoneBrowser({})).toBe(false);
  });
});
