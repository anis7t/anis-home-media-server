# Phase 13 Implementation Plan — Endless Home Discovery Feed, Genre Rails & Hierarchical Tree Navigation

**Working Branch:** `feat/phase-13-flutter-home-feed-navigation`  
**Target:** Flutter Client (`flutter_client/` — Android Phone & Android TV / Fire TV)  
**Status:** ⏳ Pending Approval  

---

## 1. Executive Summary & Goals

Phase 13 modernizes the Android app's Home screen across both **Mobile Phones** (touch, portrait) and **Android TV / Fire TV Stick 4K** (10ft viewing distance, D-pad navigation).

Currently, the Home screen displays *Continue Watching* and a fixed 8-item *Recently Added* grid. Phase 13 transforms this into an **Endless Discovery Feed** composed of dynamic, lazily-rendered horizontal genre rails, complemented by an ultra-translucent **Frosted Obsidian Glass Tree Drawer** replacing traditional menus with an interactive, hierarchical catalog tree.

---

## 2. Scope

### In-Scope:
1. **Dynamic Endless Home Feed:**
   - **Section 1:** *Continue Watching* rail (if user has active in-progress media).
   - **Section 2:** *Recently Added* rail with latest additions.
   - **Sections 3..N:** *Genre Rails* (Action, Sci-Fi, Thriller, Drama, Animation, Comedy, etc.), dynamically derived from library metadata, sorted by movie density, and lazily rendered as the user scrolls downward.
   - Individual rails support smooth horizontal swiping, poster artwork, rating chips, year badges, and quick-play / details triggers.
2. **Modern Frosted Obsidian Glass Tree Navigation:**
   - A slide-out navigation drawer with `BackdropFilter` (25px Gaussian blur) and translucent obsidian styling (`#05060A` at 75% opacity).
   - Expandable hierarchical category tree:
     - 🎬 **All Movies** (with item count)
     - 🕒 **Recently Added**
     - 🏷️ **Genres** (expandable leaves with per-genre movie counts)
     - 📅 **Decades / Release Eras** (expandable: 2020s, 2010s, 2000s, Classics)
     - ⚙️ **Settings & Administration**
   - Active neon-red indicators, glowing accents, and instant filtering.
3. **Android TV & Fire TV D-Pad Focus Parity:**
   - Bidirectional 2D D-pad grid navigation: Left/Right scrolls cards within a rail; Up/Down transitions focus between vertical rails.
   - TV-optimized drawer activation via header menu action or remote Menu key.
4. **Resilience & Testing:**
   - Unit tests for feed generation, widget tests for tree drawer and endless scrolling, zero `flutter analyze` issues.
   - Production build v1.4.0 (Build 146) verified on physical Android phone via ADB (`192.168.1.6:40283`).

### Deliberately Out-of-Scope:
- Backend Rust schema alterations (all required metadata: `genres`, `year`, `progress`, `created_at` already exist in the database and are served by `/api/movies`).
- Web SPA navigation redesign (Phase 13 is targeted specifically at the Flutter Client for Android Phone & TV).

---

## 3. Architecture & Component Design

```text
┌────────────────────────────────────────────────────────────────────────┐
│              ANIS' HOME MEDIA SERVER — DISCOVERY & FEED                │
├────────────────────────────────────────────────────────────────────────┤
│  [🌿 Tree]  Anis' Home Media Server                    [↻ Scan] [⚙]    │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  ▶ CONTINUE WATCHING (Horizontal Rail - In-Progress Items)             │
│    [Poster: 2001 A Space Odyssey | 64%] [Poster: Spider-Man | 22%]     │
│                                                                        │
│  ✨ RECENTLY ADDED (Horizontal Rail - Latest Releases)                 │
│    [28 Days Later] [28 Weeks Later] [28 Years Later] [Alien Romulus]   │
│                                                                        │
│  🍿 ACTION & ADVENTURE (Genre Rail 1 • 12 Movies)          Explore →   │
│    [Movie Card 1] [Movie Card 2] [Movie Card 3] [Movie Card 4] ...     │
│                                                                        │
│  🚀 SCI-FI & FANTASY (Genre Rail 2 • 9 Movies)             Explore →   │
│    [Movie Card 1] [Movie Card 2] [Movie Card 3] [Movie Card 4] ...     │
│                                                                        │
│  🎭 DRAMA & THRILLER (Genre Rail 3 • 8 Movies)             Explore →   │
│    [Movie Card 1] [Movie Card 2] [Movie Card 3] [Movie Card 4] ...     │
│                                                                        │
│  ▼ (Endless Lazy-Loading as user scrolls down: Animation, Horror, etc.)│
└────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────┐
│  🌿 FROSTED OBSIDIAN TREE DRAWER (Glass)     │
├──────────────────────────────────────────────┤
│  ▼ 🎬 All Movies (33)                        │
│  ▼ 🕒 Recently Added                         │
│  ▼ 🏷️ Genres                                  │
│    ├─ Action (12)                            │
│    ├─ Sci-Fi (9)                             │
│    ├─ Thriller (8)                           │
│    ├─ Drama (7)                              │
│    └─ Animation (4)                          │
│  ▼ 📅 Release Eras                           │
│    ├─ 2020s                                  │
│    ├─ 2010s                                  │
│    └─ Classic Cinema (<2000)                 │
│  ──────────────────────────────────────────  │
│  ⚙️ Settings & System Admin                   │
└──────────────────────────────────────────────┘
```

---

## 4. Work Breakdown & Implementation Slices

### Slice 13.1: Feed Data Engine & Multi-Rail Controller
- Extend `LibraryController` or implement `HomeFeedNotifier` to partition catalog movies into:
  - `continueWatching` (items with active progress).
  - `recentlyAdded` (sorted by date/id descending).
  - `genreRails`: Map of `Genre -> List<MovieItem>`, ordered by movie count descending.
- Implement lazy batching/pagination: load first 3 genre rails on mount, append additional rails as scroll threshold passes 80%.

### Slice 13.2: Modern Frosted Obsidian Tree Drawer Widget
- Create `FrostedTreeDrawer` in `flutter_client/lib/features/home/presentation/widgets/frosted_tree_drawer.dart`.
- Apply `BackdropFilter(filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25))`.
- Construct expandable tree node tiles with smooth rotation chevrons, counts badges, and neon-red active highlight.
- Connect leaf actions to filter navigation (navigates to `/library` with pre-applied filter or scrolls home feed directly to that rail).

### Slice 13.3: Endless Horizontal Feed on Mobile Phone
- Refactor `home_screen.dart` to use `CustomScrollView` with `SliverToBoxAdapter` and `SliverList.builder` for infinite/lazy rails.
- Build dedicated `GenreRailWidget` with header, movie count chip, "Explore →" action, and horizontally swipeable card strip.
- Add edge-swipe gesture detection to summon the Frosted Tree Drawer.

### Slice 13.4: Android TV / Fire TV 10ft Focus & Remote Parity
- Add `TvFocusable` wrappers to the tree drawer items and rail cards.
- Implement directional focus traversal ensuring D-pad Up/Down navigates cleanly between vertical rails and Left/Right navigates within each rail.
- Map remote Menu key and header icon to open the tree drawer.

### Slice 13.5: Test Suite, Code Quality & Release Packaging
- Write unit tests in `test/features/home/home_feed_test.dart` and `test/features/home/frosted_tree_drawer_test.dart`.
- Run `flutter analyze` (enforce 0 warnings, 0 errors).
- Compile and publish signed production release APK `v1.4.0` (Build 146).

### Slice 13.6: On-Device Hardware ADB Verification
- Install APK on connected phone at `192.168.1.6:40283`.
- Verify tree drawer expansion, genre navigation, and endless feed scrolling via live ADB screencaps.

---

## 5. Exit Criteria & Checkable Outcomes

1. **Home Feed:** Displays *Continue Watching*, *Recently Added*, and at least 3 genre rails on initial load, loading further genre rails seamlessly as user scrolls down.
2. **Frosted Tree Drawer:** Opens via top-left modern icon button or left-edge swipe, rendering an expandable frosted glass tree with live movie counts per genre and decade.
3. **Android TV Parity:** D-pad navigation moves effortlessly across horizontal rails and vertical feed sections without losing focus.
4. **Code Quality:** All unit and widget tests pass, `flutter analyze` reports 0 issues.
5. **Physical Device Proof:** Production APK v1.4.0 installed and verified via ADB screencaps on `192.168.1.6:40283`.

---

## 6. Risks & Mitigations

- **Risk:** High memory usage or frame drops when rendering dozens of horizontal image rails on mobile.  
  *Mitigation:* Use `ListView.builder` inside rails and lazy slivers for vertical rails, with image caching and constrained poster dimensions.
- **Risk:** D-pad focus getting trapped inside a horizontal rail on TV.  
  *Mitigation:* Explicit `FocusNode` directional navigation and standard Flutter `FocusScope` traversal keys.
