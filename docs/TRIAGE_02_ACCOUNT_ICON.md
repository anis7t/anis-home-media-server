# Triage Plan — Issue 14.2: Account Icon Missing Across Pages (Web)

**Date:** 2026-10-23 (IST 03-18)
**Issue:** [`docs/Current issues.md`](../docs/Current%20issues.md) → Issue 14, fault 2
**Branch:** `fix/issue-14-user-reported-faults`

---

## 1. Fault

The user account icon is **not present through all pages** of the web app — some pages lack the
signed-in identity affordance.

## 2. Context

- Unified navigation header work (`feat/unified-header-navigation`) may have moved the account
  affordance; pages may render their own headers or override.

## 3. Hypotheses

1. The account affordance is only in the shared header, and some pages render their own header.
2. The affordance renders conditionally on auth state that is not yet settled on some pages.

## 4. Verification approach

- Grep components for the account icon / `/account` link; list pages that render their own header.

## 5. Exit criteria

- The account icon renders on every page for signed-in users, or the missing set is enumerated.

## 6. Risks / open decisions

- UI-only; no backend contract impact.

---

**Next step (pending approval):** audit pages, then patch the shared pattern.
