# CodeIsland Notch Customization — Design Spec

**Date:** 2026-04-08
**Status:** Draft (pending review)
**Target version:** v1.10.0
**Author:** Brainstorming session with project owner

## 1. Background

CodeIsland today renders a fixed black-on-white notch overlay locked to
the MacBook Pro hardware notch. All colors, fonts, notch dimensions, and
buddy/usage-bar visibility are hardcoded. Users cannot customize any
appearance or layout aspect of the notch, and the idle-state notch is
always as wide as its maximum expanded state — leaving large empty
space in the middle of the menu bar even when there is almost nothing
to show.

This spec defines a set of seven user-facing customization features and
the supporting architecture to deliver them in v1.10.0 as a single
release.

## 2. Goals

1. Let the user hide the buddy (pet) indicator via a setting.
2. Let the user hide the usage-bar (rate-limit %) indicator via a
   setting.
3. Let the user resize the notch via an in-place live edit mode on the
   notch body itself, covering both MacBooks with and without a
   hardware notch.
4. Let the user slide the notch horizontally along the top edge of the
   screen (not free-floating).
5. Let the user pick a theme from six built-in presets, with smooth
   color transitions on switch.
6. Make the notch auto-shrink to fit its content at idle and expand up
   to a user-configured maximum width when content grows.
7. Let the user scale all notch fonts via a four-step size picker.

## 3. Non-goals

- Fully free-floating notch positioning (rejected: breaks the notch's
  visual identity; hardware notch on the Mac remains regardless).
- User-defined custom themes with color pickers (rejected this round:
  six curated presets cover the intent; a future iteration can add a
  custom palette editor without breaking the current architecture).
- Vertical resizing of the notch (rejected: height is a visual
  signature; hardware notch height is fixed at ~37pt).
- Undo/redo history beyond a single Cancel-to-origin rollback in live
  edit mode.
- Refactoring `@AppStorage` keys unrelated to the notch (notifications,
  CodeLight, behavior tabs stay untouched).
- Changing the notarization / release pipeline.

## 4. User-facing design

### 4.1 Settings surface

A new "Notch" section is added inside the existing **Appearance** tab
of `SystemSettingsView`. No new top-level tab.

```
Appearance Tab
  ...existing controls...

  ─── Notch ───

  Theme              [ Classic       ▾ ]      ← 6 presets, mini swatch in each row
  Font Size          [ S | M | L | XL ]       ← Segmented picker
  Show Buddy         [   ]                    ← Toggle
  Show Usage Bar     [   ]                    ← Toggle
  Hardware Notch     [ Auto          ▾ ]      ← Auto | Force Virtual | Force Hardware
  [ Customize Size & Position… ]              ← Big button → enter live edit mode
```

### 4.2 Live edit mode

A one-shot interaction that takes over the notch itself to let the user
resize, reposition, and preview the geometry. Entered from the
Customize button in Settings. While in edit mode:

- The notch shows **simulated Claude content** (short / medium / long
  messages rotating every 2s) so the user can see how real content
  will render at the chosen max width.
- A **dashed border** and a **soft neon-green breathing gradient**
  surround the notch.
- The Settings window is minimized/hidden so the user can see the real
  notch.

Floating controls appear near the notch:

```
               ┌─────────────────────────────┐
               │   [simulated Claude text]   │
               └─────────────────────────────┘
          ◀                                         ▶       ← Neon green arrow buttons (resize)

                [⊙ Notch Preset]  [✋ Drag Mode]              ← Action buttons

                     [ Save ]    [ Cancel ]                  ← Neon green / neon pink
```

Interactions:

- **Arrow buttons (◀ ▶):** one click = symmetric (mirror) resize by
  2pt. `⌘+click` = 10pt. `⌥+click` = 1pt. Resize always shrinks/grows
  the notch around its current center.
- **Drag on the left/right edge of the notch:** continuous mirror
  resize, equivalent to the arrow buttons.
- **Notch Preset button:** sets `maxWidth = hardwareNotchWidth + 20pt`
  (with small breathing room). Also flashes a dashed width marker
  underneath the notch for 2s so the user sees the hardware notch
  reference width. On a Mac without a hardware notch, this button is
  disabled with a help tooltip: *"Your device doesn't have a hardware
  notch"*.
- **Drag Mode button:** toggles the edit sub-mode from resize to move.
  On toggle, the entire notch flashes once. While in drag mode,
  dragging the notch moves it **horizontally only** along the top edge
  of the screen — y is locked to the top. Click Drag Mode again to
  return to resize sub-mode.
- **Save (neon green):** commits all changes made during the edit
  session via `store.commitEdit()`, tears down the overlay, restores
  the Settings window.
- **Cancel (neon pink):** rolls back all changes to the snapshot taken
  at `enterEditMode()` via `store.cancelEdit()`, tears down the
  overlay, restores the Settings window.

### 4.3 Runtime auto-width behavior

At runtime, the notch width is computed every frame as:

```
clampedWidth = max(minIdleWidth,
                   min(desiredContentWidth, store.customization.maxWidth))
```

- `minIdleWidth = 200pt` — enough for the minimum idle layout (icon +
  short label + small right-side indicator).
- `desiredContentWidth` — measured via `GeometryReader` +
  `PreferenceKey` from the actual rendered notch content.
- Width changes are animated with `.spring(response: 0.35,
  dampingFraction: 0.8)` so transitions are smooth.
- When `desiredContentWidth > maxWidth`, the offending text uses
  `.lineLimit(1).truncationMode(.tail)` to render with an ellipsis.

Effect: idle state shrinks the notch tightly around its sparse content,
solving the "huge empty middle" problem in the user's screenshot.

### 4.4 Theme switching

Switching the theme picker immediately mutates
`store.customization.theme`. All views reading palette colors re-render.
The notch root view carries
`.animation(.easeInOut(duration: 0.3), value: store.customization.theme)`
so all colors interpolate smoothly. Status colors (success / warning /
error) come from Asset Catalog entries under `NotchStatus/` and are
**not** palette-controlled — they preserve semantic meaning across
themes.

## 5. Architecture

### 5.1 State model

A single value type persists all notch customization state:

```swift
struct NotchCustomization: Codable, Equatable {
    var theme: NotchThemeID = .classic
    var fontScale: FontScale = .default
    var showBuddy: Bool = true
    var showUsageBar: Bool = true
    var maxWidth: CGFloat = 440
    var horizontalOffset: CGFloat = 0
    var hardwareNotchMode: HardwareNotchMode = .auto

    static let `default` = NotchCustomization()
}

enum NotchThemeID: String, Codable, CaseIterable, Identifiable {
    case classic, paper, neonLime, cyber, mint, sunset
    var id: String { rawValue }
}

enum FontScale: CGFloat, Codable, CaseIterable {
    case small = 0.85
    case `default` = 1.0
    case large = 1.15
    case xLarge = 1.3
}

enum HardwareNotchMode: String, Codable {
    case auto        // detect via NSScreen.safeAreaInsets
    case forceOn     // user has notch, wants virtual notch behavior
    case forceOff    // user lacks notch, wants fake notch overlay
}
```

### 5.2 Store

```swift
@MainActor
final class NotchCustomizationStore: ObservableObject {
    static let shared = NotchCustomizationStore()

    @Published private(set) var customization: NotchCustomization
    @Published var isEditing: Bool = false

    private var editDraftOrigin: NotchCustomization?
    private let defaultsKey = "notchCustomization.v1"

    private init() {
        self.customization = Self.loadFromDefaults() ?? Self.migrateFromLegacyOrDefault()
    }

    func update(_ mutation: (inout NotchCustomization) -> Void) {
        mutation(&customization)
        save()
    }

    func enterEditMode() {
        editDraftOrigin = customization
        isEditing = true
    }

    func commitEdit() {
        editDraftOrigin = nil
        isEditing = false
        save()
    }

    func cancelEdit() {
        if let origin = editDraftOrigin {
            customization = origin
            save()
        }
        editDraftOrigin = nil
        isEditing = false
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(customization) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func loadFromDefaults() -> NotchCustomization? {
        guard let data = UserDefaults.standard.data(forKey: "notchCustomization.v1") else { return nil }
        return try? JSONDecoder().decode(NotchCustomization.self, from: data)
    }

    private static func migrateFromLegacyOrDefault() -> NotchCustomization {
        var c = NotchCustomization.default
        let d = UserDefaults.standard
        if d.object(forKey: "usePixelCat") != nil {
            c.showBuddy = d.bool(forKey: "usePixelCat")
            d.removeObject(forKey: "usePixelCat")
        }
        return c
    }
}
```

Key design choices:

- **Pure value type** for the customization. Codable roundtrip is
  trivial, testing needs no mocks, and any mutation produces a single
  atomic `@Published` notification — no "half-updated theme" frames.
- **`update` closure API** funnels every mutation through one place so
  `save()` is called exactly once per change.
- **Live edit uses a snapshot**, not a diff log. Cancel is a single
  assignment back to the snapshot — no per-field undo.
- **Versioned UserDefaults key** (`notchCustomization.v1`) leaves room
  for future schema migrations via `.v2`, `.v3` etc.
- **Legacy migration is one-shot and destructive.** After the first
  successful save to `v1`, legacy keys (`usePixelCat`) are removed so
  they can't diverge.

### 5.3 Theme module

```swift
struct NotchPalette: Equatable {
    let bg: Color
    let fg: Color
    let secondaryFg: Color
}

extension NotchPalette {
    static func `for`(_ id: NotchThemeID) -> NotchPalette {
        switch id {
        case .classic:  return NotchPalette(bg: .black,               fg: .white,               secondaryFg: Color(white: 1, opacity: 0.4))
        case .paper:    return NotchPalette(bg: .white,               fg: .black,               secondaryFg: Color(white: 0, opacity: 0.55))
        case .neonLime: return NotchPalette(bg: Color(hex: 0xCAFF00), fg: .black,               secondaryFg: Color(white: 0, opacity: 0.55))
        case .cyber:    return NotchPalette(bg: Color(hex: 0x7C3AED), fg: Color(hex: 0xF0ABFC), secondaryFg: Color(hex: 0xC4B5FD))
        case .mint:     return NotchPalette(bg: Color(hex: 0x4ADE80), fg: .black,               secondaryFg: Color(white: 0, opacity: 0.55))
        case .sunset:   return NotchPalette(bg: Color(hex: 0xFB923C), fg: .black,               secondaryFg: Color(white: 0, opacity: 0.5))
        }
    }
}
```

Status colors live in Asset Catalog under `NotchStatus/`:

```
NotchStatus/
  Success.colorset  →  #4ADE80
  Warning.colorset  →  #FB923C
  Error.colorset    →  #F87171
```

Views use `Color("NotchStatus/Success")` etc. These are **not** in the
palette and do not change with theme — they preserve semantic meaning
(approval-needed is always a warning color regardless of theme).

### 5.4 Font scaling

All notch text uses a helper that multiplies the base size by the
current scale:

```swift
extension View {
    func notchFont(_ baseSize: CGFloat, weight: Font.Weight = .medium, design: Font.Design = .monospaced) -> some View {
        self.modifier(NotchFontModifier(baseSize: baseSize, weight: weight, design: design))
    }
}

struct NotchFontModifier: ViewModifier {
    @EnvironmentObject var store: NotchCustomizationStore
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: baseSize * store.customization.fontScale.rawValue, weight: weight, design: design))
    }
}
```

All existing `.font(.system(size: N, ...))` calls in the notch tree
are replaced with `.notchFont(N, ...)`. A single grep pass identifies
every call site. Scale changes take effect immediately via the
`@EnvironmentObject` dependency.

### 5.5 Window geometry & hardware-notch detection

`NotchWindowController` subscribes to `store.$customization` and
re-applies geometry on every change. The computation flow:

```
hasHardwareNotch =
    switch hardwareNotchMode:
        .auto      → NSScreen.main?.safeAreaInsets.top > 0
        .forceOn   → true
        .forceOff  → false

baseNotchSize = hasHardwareNotch
    ? screen hardware notch dimensions from safeAreaInsets
    : synthetic default size

runtimeWidth = clamp(measuredContentWidth,
                     minIdleWidth,
                     store.customization.maxWidth)

baseX = (screen.width - runtimeWidth) / 2
clampedOffset = clamp(store.customization.horizontalOffset,
                      -baseX,
                      screen.width - baseX - runtimeWidth)
finalX = baseX + clampedOffset

notchY = screen top (always pinned)
```

The existing `ScreenObserver` already subscribes to
`NSApplication.didChangeScreenParametersNotification`. We extend its
handler to call `notchWindowController.applyGeometry()` so external
monitor plug/unplug re-runs detection.

### 5.6 New files

```
ClaudeIsland/
  Models/
    NotchCustomization.swift        ← value type, enums
    NotchTheme.swift                 ← palette definitions, NotchThemeID
  Services/State/
    NotchCustomizationStore.swift    ← ObservableObject store
  UI/Helpers/
    NotchFontModifier.swift          ← font scaling helper
  UI/Views/
    NotchLiveEditOverlay.swift       ← floating edit controls
    NotchLiveEditSimulator.swift     ← rotating simulated content
```

### 5.7 Files modified

- `ClaudeIsland/App/ClaudeIslandApp.swift` — inject
  `NotchCustomizationStore.shared` as an `@EnvironmentObject` at the
  scene root.
- `ClaudeIsland/UI/Views/NotchView.swift` — replace hardcoded colors
  with palette lookups, replace `.font(.system(size:))` with
  `.notchFont(...)`, thread the store through.
- `ClaudeIsland/UI/Views/ClaudeInstancesView.swift` — gate buddy and
  usage bar visibility on `store.customization.showBuddy` /
  `.showUsageBar`.
- `ClaudeIsland/UI/Views/BuddyASCIIView.swift` — use palette `fg`
  instead of hardcoded white; apply `notchFont`.
- `ClaudeIsland/UI/Views/SystemSettingsView.swift` — add the new Notch
  subsection inside the Appearance tab, add the "Customize Size &
  Position…" entry point.
- `ClaudeIsland/Core/WindowManager.swift` and
  `ClaudeIsland/UI/Views/NotchWindowController.swift` — apply geometry
  from the store, subscribe to store changes.
- `ClaudeIsland/Services/ScreenObserver.swift` — reapply geometry on
  screen-change notifications.
- `ClaudeIsland/Assets.xcassets/` — add `NotchStatus/` color set.

## 6. Interaction flow diagrams

### 6.1 Enter edit mode

```
User taps "Customize Size & Position…"
  → SystemSettingsView.onCustomize()
  → store.enterEditMode()                       ← snapshot taken, isEditing = true
  → SystemSettingsWindow.hide()
  → NotchView observes isEditing
  → renders NotchLiveEditOverlay over notch
  → NotchLiveEditSimulator starts rotating fake content
```

### 6.2 Resize via arrow button

```
User clicks ◀
  → NotchLiveEditOverlay.onLeftArrow()
  → store.update { $0.maxWidth = max(minWidth, $0.maxWidth - 2) }
  → save() fires
  → NotchWindowController observes customization change
  → applyGeometry() recalculates and animates frame
```

### 6.3 Cancel

```
User clicks Cancel
  → NotchLiveEditOverlay.onCancel()
  → store.cancelEdit()
  → customization = editDraftOrigin
  → save() fires with original values
  → NotchWindowController applyGeometry() returns to pre-edit
  → SystemSettingsWindow.show() restores Settings
  → NotchLiveEditOverlay disappears (driven by isEditing = false)
```

## 7. Testing strategy

### 7.1 Unit tests

```
ClaudeIslandTests/
  NotchCustomizationTests.swift
    - Codable roundtrip preserves every field
    - Decoding missing fields uses defaults (forward-compat)
    - FontScale rawValue mapping (0.85 / 1.0 / 1.15 / 1.3)
    - All HardwareNotchMode cases decode

  NotchCustomizationStoreTests.swift
    - init reads v1 from UserDefaults when present
    - init migrates from usePixelCat legacy key when v1 missing
    - init returns default when no keys exist
    - update(_:) closure mutates and saves exactly once
    - enterEditMode snapshots draft origin
    - commitEdit clears origin, persists changes
    - cancelEdit restores origin and persists
    - Concurrent update calls do not corrupt state (main-actor isolated)

  NotchThemeTests.swift
    - All 6 NotchThemeID cases produce valid, equatable palettes
    - Palettes do not contain status colors
    - Theme raw strings match their enum case names

  AutoWidthTests.swift
    - clampedWidth ≤ maxWidth for all desiredContentWidth
    - clampedWidth ≥ minIdleWidth for all desiredContentWidth
    - Truncation predicate triggers when content > maxWidth
    - Width responds to store mutations
```

### 7.2 Snapshot tests

Use the existing testing infrastructure (check for existing snapshot
setup during implementation). Render the notch view with:

- 6 themes × 4 font scales = 24 idle-state snapshots.
- Live edit overlay in each sub-mode: resize, drag-mode, with
  preset marker visible.
- Empty content (minIdleWidth). Short content. Long-truncated content.

### 7.3 Manual QA checklist

Written to `docs/qa/notch-customization.md`:

- [ ] Enter edit mode → arrow buttons resize symmetrically → Save →
      close & relaunch app → width preserved.
- [ ] Enter edit mode → drag an edge → Cancel → width reverts.
- [ ] Enter edit mode → Notch Preset → width snaps to hardware notch
      width + 20pt → dashed marker flashes for 2s.
- [ ] On a MacBook Air without a hardware notch (or with Hardware
      Notch set to Force Virtual) → Notch Preset button disabled
      with help tooltip.
- [ ] Drag Mode → click → notch flashes → dragging moves horizontally
      only, y locked.
- [ ] Switch between all 6 themes → transition animates ≤ 0.3s,
      no flicker.
- [ ] Change font size to XL → all text (including buddy) scales
      proportionally, no layout breakage.
- [ ] Disable Show Buddy → pet disappears, surrounding layout
      collapses cleanly without gaps.
- [ ] Disable Show Usage Bar → usage bar disappears, idle-state notch
      becomes narrower.
- [ ] Idle state with only icon + time visible → notch auto-shrinks
      tight around content (the screenshot case).
- [ ] Claude sends a very long message → notch expands to configured
      maxWidth, then truncates with ellipsis.
- [ ] Plug in external monitor → notch migrates per Hardware Notch
      Mode setting without restart.

## 8. Migration & rollout

### 8.1 User data migration

On first launch after upgrade:

1. `NotchCustomizationStore.init` checks for `notchCustomization.v1`.
2. If absent, it calls `migrateFromLegacyOrDefault()`:
   - Reads `usePixelCat` → `showBuddy`.
   - Removes `usePixelCat` from UserDefaults.
   - Returns a `NotchCustomization` with defaults for all other
     fields.
3. Saves to `.v1` immediately so the migration is idempotent.

### 8.2 Release

- Single PR against `main` targeting **v1.10.0**.
- Bumped `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
- Because Apple notarization is still blocked on case
  `102860621331` (error 7000), v1.10.0 ships as a pre-release
  "signed but not notarized" via GitHub Releases, mirroring the
  v1.9.0-rc1 pattern. Homebrew cask in `xmqywx/homebrew-codeisland`
  is updated with the new version + sha256 + the postflight
  `xattr -dr com.apple.quarantine` hook still in place.
- README install notice and Homebrew README are unchanged — they
  already cover the unnotarized state generically.

## 9. Open questions

None. All clarifying questions from the brainstorming session have
been answered and incorporated.

## 10. Appendix: brainstorming decisions trace

| # | Feature | Decision |
|---|---|---|
| Scope | 7 features in one release | Chosen: A (all in one design + implementation) |
| #4 Drag | Drag semantics | B — slide along top edge only (not free-floating) |
| #3 Camera mode | Meaning of "camera mode" | Interpretation 1 — has-notch vs no-notch modes, virtual fallback for no-notch |
| #3 Size UX | Size adjustment surface | Live edit mode in-place on the notch itself, not a separate mockup page |
| #3 Height | Vertical resize? | Not adjustable — height is the visual signature |
| #3 Save semantics | What Save persists | Save max width (auto-width runtime uses it as the ceiling) |
| #3 Simulated content | What edit mode previews | Rotating fake Claude messages (short/medium/long) |
| #3 Notch Preset | On no-notch Macs | Disabled + help tooltip |
| #3 Cancel | Rollback granularity | Snapshot at enter; restore on cancel |
| #5 Themes | Preset count | 6 (Classic, Paper, Neon Lime, Cyber, Mint, Sunset) |
| #5 Transition | Switching animation | 0.3s fade |
| #5 Scope | Status color semantics | Status colors preserved, not overridden by theme |
| #6 Auto-width | Behavior at idle | Shrink to content; expand up to user's saved maxWidth on demand |
| #6 Overflow | When content > maxWidth | Single-line truncation with tail ellipsis |
| #7 Font | Scale vs absolute | Relative scale factor (0.85 / 1.0 / 1.15 / 1.3) |
| #7 UI | Control type | Segmented picker, 4 discrete steps |
| Arch | State management | Centralized `NotchCustomizationStore` (Y), not scattered AppStorage (X), not Redux (Z) |
| Arch | Persistence | Single versioned UserDefaults key (`notchCustomization.v1`) |
| Arch | Refactoring scope | Only notch-related AppStorage; leave notification/codelight/behavior untouched |
