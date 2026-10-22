import { render } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { SeekRipples } from './SeekRipples';

describe('SeekRipples', () => {
  it('renders both ripples hidden by default when not visible', () => {
    render(<SeekRipples leftVisible={false} rightVisible={false} />);
    const left = document.getElementById('seekRippleLeft');
    const right = document.getElementById('seekRippleRight');

    expect(left).toHaveAttribute('hidden');
    expect(left?.style.display).toBe('none');
    expect(right).toHaveAttribute('hidden');
    expect(right?.style.display).toBe('none');
  });

  it('reveals left ripple with custom seconds', () => {
    render(<SeekRipples leftVisible={true} rightVisible={false} leftSec={20} />);
    const left = document.getElementById('seekRippleLeft');
    const right = document.getElementById('seekRippleRight');

    expect(left).not.toHaveAttribute('hidden');
    expect(left?.style.display).toBe('flex');
    expect(document.getElementById('seekRippleLeftSec')?.textContent).toBe('20');
    expect(right).toHaveAttribute('hidden');
  });

  it('reveals right ripple with custom seconds', () => {
    render(<SeekRipples leftVisible={false} rightVisible={true} rightSec={30} />);
    const left = document.getElementById('seekRippleLeft');
    const right = document.getElementById('seekRippleRight');

    expect(right).not.toHaveAttribute('hidden');
    expect(right?.style.display).toBe('flex');
    expect(document.getElementById('seekRippleRightSec')?.textContent).toBe('30');
    expect(left).toHaveAttribute('hidden');
  });
});
