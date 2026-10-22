/**
 * The "the server refused us" signal, in its own module.
 *
 * This exists to break an import cycle: `client.ts` must be able to announce a
 * 401, `AuthProvider` must listen for it, and `AuthProvider` already imports
 * `account.ts`, which imports `client.ts`'s sibling `account.ts`. A shared
 * leaf module with no imports of its own is the only way all three can see the
 * same event without a cycle.
 *
 * A lazy `import()` was tried here instead and the bundler reported
 * INEFFECTIVE_DYNAMIC_IMPORT: the provider is statically imported by the shell,
 * so the module lands in the main chunk regardless and the indirection bought
 * nothing while hiding the cycle.
 */

/** Dispatched when an API call comes back 401. */
export const AUTH_LOCKED_EVENT = 'media-server:auth-locked';

export function notifyAuthLocked(): void {
  window.dispatchEvent(new CustomEvent(AUTH_LOCKED_EVENT));
}