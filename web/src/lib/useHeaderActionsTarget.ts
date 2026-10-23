/**
 * The header's page-actions slot.
 *
 * `AppShell` renders this slot inside the primary nav, before the account
 * affordance. A page that owns an action which belongs in that row — the
 * library's Upload Media — portals into it instead of opening a second row
 * beneath the header. The id lives here so the shell and the page cannot drift
 * apart: a rename in one file would silently drop the control from the other.
 */
import { useEffect, useState } from 'react';

export const HEADER_ACTIONS_SLOT_ID = 'header-page-actions';

/**
 * Resolve the slot after mount.
 *
 * A page renders before the shell's DOM exists (the page is the shell's child),
 * so `document.getElementById` has to run in an effect. The first paint simply
 * has no action to place, which is invisible: the slot is empty either way.
 */
export function useHeaderActionsTarget(): HTMLElement | null {
  const [target, setTarget] = useState<HTMLElement | null>(null);

  useEffect(() => {
    setTarget(document.getElementById(HEADER_ACTIONS_SLOT_ID));
  }, []);

  return target;
}
