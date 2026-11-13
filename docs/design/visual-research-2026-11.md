# Visual redesign research (2026-11-13)

Raw output of the audit + research workflow. Not yet an agreed plan: the critique below corrects the direction.

# Redcast design direction

Grounded in `AGENTS.md`, `docs/ui.md`, `Tinycast/DesignSystem/Theme.swift`, `GlassEffectView.swift`, `RaycastPalette.swift` and the root surface in `Tinycast/Palette/RootPaletteView.swift:357-370`. Nothing was built or rendered. Every number below is a starting value to tune from screenshots over a light wallpaper, side by side with Raycast v2, because no published Raycast spec exists.

## 1. Verdict

- **The foundations are already top-tier.** The alpha ramp, `InterfaceMetrics`, armed hover, edge dissolve, concentric menus and the sidebar pill should not change.
- **The main panel is glass in name only.** A bare `NSGlassEffectView()` sits under a 40% black scrim and a SwiftUI clip, so it has no edge of its own, no rim and no depth. This is the main reason it does not look premium.
- **There is no material vocabulary.** About 33 sites hand-assemble three recipes; shadows, motion curves, focus and disabled opacity are literals.
- **Interaction feels static.** Hover snaps, most controls have no press state, and almost nothing transitions.
- **The titled windows read as a different product.** Settings, Onboarding and AI Chat are opaque stock surfaces; the tooltip is an opaque grey tile; the composer's glass has nothing behind it.

## 2. Target visual language

**Principle:** glass is the backdrop and the floating layer; content stays flat ramp fills. Never glass on glass, never glass rows.

### Materials: new `Theme.Glass` roles behind one `surface(_:in:)` modifier

| Role | Surfaces | Glass | Tint (dark / light) | Scrim above glass | Rim |
|---|---|---|---|---|---|
| `panel` | palette, Notes, Quick Action, Camera | `NSGlassEffectView`, `.regular`, own `cornerRadius` | `tintColor` black 0.30 / white 0.40 | `panelScrim` 0.40 → 0.14 / 0.55 → 0.22 | yes |
| `hud` | message pill, volume box | same AppKit twin | black 0.24 / white 0.36 | 0.10 / 0.18 | yes; pill keeps its tone glow |
| `modal` | dialog, Settings editor panels | `.glassEffect(.regular)` | none | new `modalScrim` 0.28 / 0.40 | yes |
| `menu` | `PopoverMenu`, note switcher, heading menu, recorder callout | `.regular` | none | none | yes |
| `control` | action pill, menu circle, formatting bar, chips, composer, find bar, Jump to Latest | `.regular.interactive()` (today's `frosted`) | accent tint only for one live state, such as dictation listening | none | system edge |
| `chip` | tooltip, preview type badges, voice-mode caption | `.regular` | none | none | yes |
| `overlayCard` | command picker, note picker, chat cards | `.regular` | `windowSurface` at 0.55 | none | yes, plus `Shadow.card` |

- **Rim:** a gradient stroke at one device pixel (`Size.rimWidth`). `Colors.rimTop` is ramp 0.22 dark and `rimBottom` 0.06; in light, the top is white 0.70 and the bottom black 0.08, through `adaptive`.
- **Sheen:** the existing `sheen` 0.04 as a top gradient on `panel` and `modal` only.
- **Shadow:** borderless windows keep the system window shadow only. New `Theme.Shadow.card` (black 0.18, radius 12, y 4) and `.floating` (black 0.25, radius 24, y 8) are for in-window overlays in titled windows and replace `tooltipShadow` reuse.
- **Titled windows** (Settings, AI Chat, Onboarding): a behind-window `NSVisualEffectView` plus a new `Colors.windowScrim`, not `glassEffect`. Stock grouped `Form` cards then float on a translucent ground.
- **Extensions** keep their own copy of any recipe inside `Features/Extensions/`.

### Radii
- Add primitives `r4, r6, r8, r10, r12, r14, r16, r20, r26`; the 23 semantic names become aliases.
- Concentric rule: inner = outer − inset, with a floor of 6.
- Values that change: lead cards and preview stage cards 10 → 14; new `chatBubble` 16. Rows stay 10, menus 16/10, panel 26.

### Type
Stay on system text styles so Interface Size keeps working.
- Row title `.body`; subtitle `.callout` in `textSecondary`; trailing kind label moves to `textTertiary`.
- Section headers use the existing token `.subheadline.weight(.medium)` in `textSecondary` everywhere, including emoji and Information headers.
- New: `previewTitle` (`.title3` semibold), `paneHeroTitle` (`.title2` semibold), `emptyTitle` (`.headline`), `badge` (`.caption` medium).
- `.monospacedDigit()` on every changing number.

### Spacing and sizes
- The scale is unchanged: 4 inside a component, 8 between components.
- New `Size.inlineControl` 24, `Size.rimWidth` (device pixel), `Size.splitListWidth` (renames `clipboardListWidth`).
- `Size.hairline` stays 1pt for content rules; rims use `rimWidth`. That gives two named roles in place of two accidental values.

### Colour
- Accent stays Raycast red and selection stays the `AccentSelection` wash.
- `Colors.focusRing`: accent at 0.55 as a 2pt ring plus a 0.15 halo, shared by every field chrome.
- `Theme.Opacity.disabled` 0.45 and `.inactive` 0.6, the latter driven by `@Environment(\.appearsActive)`.
- Status badges: a hue at 0.15 fill with hue ink, built on `warning/success/destructive`.
- Increase Contrast: `ramp` and `adaptive` already resolve per appearance, so the high-contrast appearance names can lift separators and strokes from 0.10 to 0.22 and double the rim. Reduce Transparency: scrims become a near-opaque elevated fill.

### States
- Keyboard selection stays instant.
- Hover: `rowHover` 0.05, eased over 0.12s, state kept on the row and movement-armed.
- Press: `controlPressed` plus a 0.97 scale on `BarButton`, the menu circle, pills and segments; menu rows get a pressed fill with no height change.

### Motion: new `Theme.Motion`
- `hover` easeOut 0.12; `press` easeOut 0.08; `swap` `.snappy(0.20)`; `settle` `.smooth(0.30)`.
- `enter`: `.snappy(0.22)` with scale 0.97 (was 0.94); `exit` easeIn 0.12.
- Absorbs `RoomMotion.glide` and `MenuMotion.chevronAnimation`. Everything still flows through `motionScope()`.

### Where Dark changes, deliberately
1. `panelScrim` dark 0.40 → 0.14, with the weight moved into the glass tint.
2. Dialog and editor scrim move to `modalScrim`.
3. Tooltip, Jump to Latest and overlay cards go from opaque or `.ultraThinMaterial` to glass.
4. Lead cards gain `cardStroke`.
5. Trailing labels move to tertiary.
6. Settings and Onboarding windows become translucent.

No existing ramp stop changes value.

## 3. Phased plan

### Phase 1: foundation (M–L, medium risk)
- **Goal:** one vocabulary, plus proof that the panel glass works.
- **Gate first:** behind a Debug flag, check that the palette renders *active* glass with its own `cornerRadius` and `tintColor`. Apple forum threads 818901 and 810314 report inactive-looking glass in non-key panels and a stale backdrop on 26.2. Also check the macOS 27 tint slider range. If the gate fails, keep the SwiftUI clip and ship rim, tint and thinner scrim only.
- **Files:**
  - `DesignSystem/Theme.swift`: `Glass`, `Shadow`, `Motion`, `Opacity`, the new colours, radius primitives.
  - `DesignSystem/GlassEffectView.swift`: radius, tint, style parameters.
  - New `DesignSystem/GlassSurface.swift`.
  - `InterfaceMetrics.swift` and `Tests/interface-size-test`.
  - Mechanical migration of the ~30 call sites, `frosted` included.
  - `docs/ui.md`: rewrite idea #5, the clip-order invariant and the Liquid Glass section.
- **Risk:** corner fringing and text contrast over bright wallpaper.
- **Verify:** before and after screenshots of palette, Notes and both HUDs, Dark and Light, over a light and a busy wallpaper, with Reduce Transparency and Increase Contrast on.
- **Rule for later phases:** add tokens in your own `Theme` extension file, as `RaycastPalette.swift` does, never in `Theme.swift`.

### Phase 2: palette shell (M, medium)
- **Goal:** the hero surface.
- **Files:** `Palette/RootPaletteView.swift`, `Features/Launcher/UI/LauncherList.swift`, `LeadCard.swift`, `SectionHeader.swift`, `CompactFavoritesRow.swift`, `DesignSystem/BarButton.swift`, `PopoverMenu.swift`, `Tooltip.swift`, `Palette/EmptyResults.swift`.
- **Work:**
  - `GlassEffectContainer` around the footer controls; a back-button chip.
  - A new `.paletteRow(selected:)` modifier that owns fill and hover ease.
  - Press states, lead-card stroke, glass tooltip, `.help` → `.tooltip`.
  - `contentTransition` on the pill label and header glyph.
  - `EmptyResults` v2.
- **Risk:** repaint cost on the keystroke path; `palette-navigation-test`.
- **Verify:** screen recording of typing and held arrows.

### Phase 3: Settings (M, medium)
- **Goal:** translucent, structured, alive.
- **Files:** `Features/Settings/SettingsWindowChrome.swift`, `DesignSystem/SettingsComponents.swift`, `SettingsDetailView.swift`, `SettingsSidebarView.swift`, `Panes/PermissionsSettingsView.swift`, `GeneralSettingsView.swift`, the ~25 pane files, `HotKeys/UI/ShortcutRecorder.swift`.
- **Work:**
  - Behind-window material plus `windowScrim`.
  - Pane hero, visible sidebar group headers, `SettingsStatusBadge`.
  - Ghost selects; hover, press and focus on custom controls.
  - Pane crossfade.
  - Permissions as one table.
  - System dialogs and popovers replaced by `DialogController` and editor panels.
- **Risk:** muddy system card fills over bright wallpaper.
- **Verify:** every pane in Dark and Light.

### Phase 4: overlays and first run (M–L, medium)
- **Files:** `Windows/HUD/*`, `Windows/Dialog/DialogView.swift`, `DesignSystem/ModalActionButtonStyle.swift`, `Features/Dictation/UI/DictationPanel.swift`, `VoiceAI/UI/VoiceModeCaption.swift`, `Notes/UI/*`, `Windows/About/AboutView.swift`, `Features/Onboarding/*`.
- **Work:**
  - Volume HUD metrics fix; pill entrance and content crossfade.
  - Dictation phase tint and transition.
  - Dialog glyph tile, press state and Tab focus.
  - Onboarding restyle: translucent window, `GlyphTile` hues, `modalAction` buttons, animated height, "Redcast" copy.
- **Risk:** the first-HUD sizing invariant; the onboarding sizing loop.

### Phase 5: AI Chat (M, low–medium)
- **Files:** `AI/UI/ChatTranscriptView.swift`, `AIEmptyState.swift`, `ChatWorkspace/UI/*`, `Agents/UI/ACPCommandPicker.swift`, `NotesAI/UI/NotePickerCard.swift`, `UsageDashboard/Settings/UsageSection.swift`.
- **Work:**
  - Glass tidy; one inspector card, switch and ring.
  - Empty-state hero with starter chips.
  - `chatBubble` radius; one code, tool and table card.
  - Message arrival transition; Swift Charts for usage.
  - Token sweep.
- **Risk:** snapshot and contrast tests; non-lazy transcript performance.
- The floating composer is excluded; see decision 3.

### Phase 6: feature screens (M, low–medium)
- **Files:** new `Palette/PaletteSplitView.swift` and `Palette/PreviewInfoSection.swift`; the seven `*Screen.swift` and preview files; 13 row structs; `Camera/UI/CameraView.swift`; `Clipboard/UI/FilePreviewStage.swift`.
- **Work:**
  - Adopt `.paletteRow`.
  - Inset stage cards with large tiles.
  - Glass type and size chips, media controls and camera shutter.
  - Preview crossfade and `numericText` transitions.
  - Accessibility parity.

### Parallelism
- After Phase 1, Phases 2, 3, 4 and 5 touch disjoint files and can run at once.
- Phase 6 starts after Phase 2, because it needs `.paletteRow` and `EmptyResults`.
- `Localizable.xcstrings` is the one shared hotspot: each phase lands its strings in a single final commit, merged serially.
- No phase needs a macOS 27-only API. If one is adopted later, it goes behind `if #available(macOS 27, *)`.

## 4. Top 10 non-visual UX improvements

1. **Dead tooltips.** `.help()` in the palette and Notes never shows in a non-activating panel (`RootPaletteView.swift:824,1678`, `BarButton.swift:131`, `SectionHeader.swift:22`, `NotesView.swift:175`, and others).
2. **System dialogs in Settings.** Fourteen `.confirmationDialog`, `.alert` and `.popover` sites break the no-system-dialog invariant.
3. **Volume HUD ignores Interface Size.** The box and its window disagree off the default size; this is a probable bug.
4. **Model chip.** It only toggles the inspector; it should open the model menu directly.
5. **Shortcuts pane.** A real table with column headers and no "Show More" paging.
6. **Empty, loading and error states.** Keycap hints, a spinner variant and inline retry; today loading shows a magnifying glass.
7. **Accessibility.** Reduce Transparency and Increase Contrast handling, missing row traits on five lists, and Tab traversal with a focus ring in dialogs.
8. **Onboarding.** The copy still says "Tinycast", and the window height jumps between steps.
9. **Settings structure.** Visible group headers; Permissions with status badges and one accent "Grant" action; `slider.horizontal.3` currently means four different things.
10. **Dead code and doc drift.** About 450 unreachable lines in `AIChatDetailView.swift`, a `ContextCard` that never shows, and stale `ui.md` values (sidebar 215 vs 218, note titlebar 44 vs 52, lead-card stroke).

## 5. Owner decisions

1. **How glassy the main panel is.** The plan moves from a 40% scrim to tinted glass with a 14% scrim. Recommendation: build three presets (today, balanced, clear) behind a Debug toggle in Phase 1 and pick from screenshots; I expect "balanced" to win.
2. **How far Settings goes.** Recommendation: a translucent window with stock `Form` cards, hero and badges now. Defer the Raycast-style unified table with inspector and fully custom cards; both are large, high-risk and touch search, history and 40+ panes.
3. **Floating composer in AI Chat.** Letting the transcript scroll under a glass composer is the only way that glass refracts anything, but it reverses a documented decision and touches tail-follow. Recommendation: yes, as a separate last phase after Phase 5.
4. **Behaviour changes bundled with the restyle.** Recommendation: accept the model-chip menu; decline window-switcher thumbnails (Screen Recording permission, performance) and the animated compact/expanded resize for now.

---

# Critique

# Review: Redcast design direction

Checked against the code and `docs/ui.md`; nothing was built or rendered. The SDK header checked is the installed macOS 27 one.

## Confirmed sound

- **Glass API is real.** `NSGlassEffectView` has `cornerRadius`, `tintColor` and `style` at macOS 26.0. Only `effectIsInteractive` is 27-only, so "no phase needs a 27 API" holds if the AppKit twin stays non-interactive.
- **Panel diagnosis is right.** `GlassEffectView.swift` is a bare `NSGlassEffectView()` under `panelScrim` and a root clip (`RootPaletteView.swift:357-370`).
- **Dead `.help()` sites exist** at the five cited lines, and `ui.md` already forbids them in the palette.
- **Fourteen system dialog sites** in Settings: exact count.
- **Volume HUD ignores Interface Size.** `VolumeHUDView` uses raw `Theme.*` where the message pill uses `metrics`.
- Gating Phase 1 on a Debug proof is the right call.

## Problems and corrections

1. **`panelScrim` is shared by 11 files**, including dialogs, both HUDs, Notes, Camera, Quick Action, Settings editors and `ExtensionSettingsEditor`. Dropping dark 0.40 → 0.14 in Phase 1 thins all of them, and the SwiftUI-glass ones get no tint to compensate until Phases 3–4. Correction: leave `panelScrim` alone and add per-role scrim tokens.
2. **"No existing ramp stop changes value" hides the real change.** Every stop was calibrated against the 0.40 scrim. Thinning it while moving trailing labels to tertiary (0.40) compounds contrast loss; `rowHover` 0.05 and the selection wash will vanish over busy wallpaper. Light with a 0.22 scrim over a dark wallpaper is the worst case. No contrast test exists. Add a measured contrast floor to the gate, and give reading surfaces (Notes, Quick Action result) a heavier scrim than the launcher.
3. **Own `cornerRadius` does not remove the root clip.** The scrim, dimming overlay and list are sibling SwiftUI layers and still need it. The gate must check that the glass corner matches the `.continuous` 26 clip, or it fringes.
4. **Double rim and shadow.** Glass with its own radius draws a system edge; a hand-drawn rim plus sheen on top duplicates it. `ui.md` already rejects hand shadows on glass, so `Shadow.card` on glass `overlayCard` contradicts it. The message pill already has a rim. Use a rim only on the fallback path.
5. **"Never glass on glass" is already false, and the plan adds more.** The action pill and menu circle sit on the panel glass today. A glass tooltip inside the palette, glass preview chips and a glass shutter add to it. Keep the tooltip matte.
6. **`MessageHUDView` records that SwiftUI glass "falls back to an opaque backing"** with nothing to lens. That applies to the `chip` and `overlayCard` roles over opaque content. The context card is deliberately glass over solid `windowBackgroundColor` for legibility; tinting it to 0.55 undoes that.
7. **Press states double up.** `frosted` is `.regular.interactive()`, which already responds to press. Adding a 0.97 scale and `controlPressed` stacks two effects, and interactive glass on the composer would flex on every click.
8. **Hover ease can trail.** Key-driven disarm (`hoverDisarmToken`) would fade over 0.12s while selection jumps, leaving ghosts on held arrows. Animate pointer-driven changes only.
9. **Accessibility claims are not true as written.** `NSAppearance.isDark` matches only `[.aqua, .darkAqua]` and `adaptive` has two slots, so Increase Contrast needs changes to `Platform/Appearance.swift` and its test. Reduce Transparency is not an appearance; a static token cannot react to it.
10. **`Size.rimWidth` as a device pixel cannot be a static token.** It needs `displayScale` and must not scale with `InterfaceMetrics`.
11. **`Opacity.inactive` via `appearsActive` may dim the whole palette**, because the app is inactive behind a non-activating panel. Scope it to titled windows; verify first.
12. **Translucent Settings and AI Chat need their own gate.** Both keep the system titlebar band, and `ui.md` records that scroll-edge materials render as hard rectangles over transparent surfaces. `NavigationSplitView` in an AppKit-built window may keep an opaque detail background. Long transcripts over wallpaper hurt reading; keep AI Chat opaque.
13. **"Tokens outside `Theme.swift`" conflicts with `ui.md`** ("New tokens go in `Theme`"). Scaled tokens also need `InterfaceMetrics.swift` and `interface-size-test`, which every phase would then touch.
14. **UX item 8 is half wrong.** The catalog already renders "Welcome to Redcast"; the Tinycast source keys are kept on purpose for upstream merges. Do not rename them.
15. **`Radius.card` 10 → 14 hits every user of `card`.** Add a new token.

## Phases that are not disjoint

- `Tooltip`, `BarButton`, `PopoverMenu` (Phase 2) and `ModalActionButtonStyle` (Phase 4) are used across Notes, Agents, Quick Actions, Camera, AI and Settings editors.
- `NotesView.swift:175` (Phase 4) is in Phase 2's `.help` sweep.
- Dialog-site fixes (Phase 3) sit in `AI/`, `Agents/` and `Extensions/` settings files and depend on `DialogView` (Phase 4).
- `ChatTranscriptView` (Phase 5) also renders in the palette.
- Absorbing `MenuMotion` edits Calendar, Quicklinks, CustomCommands, Agents and Notes.
- Shared hotspots beyond `Localizable.xcstrings`: the generated `Tinycast.xcodeproj`, the per-harness source lists in `Scripts/run-tests.sh`, `docs/ui.md` and `InterfaceMetrics.swift`.

## Missed

- **Upstream merge cost.** `FORK.md` keeps the fork close to upstream; rewriting `Theme.swift`, `RootPaletteView` and 30+ sites enlarges every merge.
- **No phase covers `Features/Extensions/`.** It has five glass sites and its own rows. The Phase 1 migration must skip them, and they need their own copies or they will lag visibly.
- **The system Clear/Tinted Liquid Glass setting** compounds with a hand-set tint; test both.
- **Open latency.** The palette opens with no fade. Gate on the existing `PaletteWindowController.show` signpost and first-frame correctness.
- **Verification method.** `ui.md` says the shell cannot screen-record, so screenshots and recordings need the owner or a harness.
- **Phase 1 is too large.** Split it into tokens, then the panel-glass gate, then migration.

---

# Appendix: audits

## Audit: design-system

# Design-system audit (read-only)

Root: `/Users/superalesha/dev/opensource/launchers/tinycast/Tinycast/` — all paths below are relative to it. Nothing was edited, built or run; every visual claim comes from reading code, not from screenshots.

## 1. How it is built today

- **Tokens.** `DesignSystem/Theme.swift` holds everything:
  - `Spacing` 2–28 (:5-28).
  - `Radius`, 23 named values (:30-56): panel 26, dialog 20, menuPanel 16, codeBlock 14, formField 12, row 10, barControl 8, keyCap 6.
  - `Size`, about 200 values (:63-302).
  - `Duration` (:304-329): enter 0.18, exit 0.12, hover 0.12.
  - `Typography` (:342-380): system text styles only; search field 20pt.
  - `Colors` (:382-486): one alpha ramp through `ramp(dark:light:)` / `adaptive`.
  - Fork additions in `RaycastPalette.swift:36-71`.
  - `InterfaceMetrics.swift` rescales a subset through `@Environment(\.metrics)`, rounded to whole points (:219-222).
- **Materials — three recipes, no token for any of them.**
  - **A, backdrop:** `panelScrim` (black 0.40 / white 0.55, Theme:394) → `GlassEffectView()` → `clipShape`. `GlassEffectView` is a bare `NSGlassEffectView()` with no radius, tint or style (`GlassEffectView.swift:3-9`).
  - **B:** `.glassEffect(.regular, in:)`, non-interactive.
  - **C:** `frosted(in:)` = `.regular.interactive()` (Theme:514-518).
- **Shadows.** Window `hasShadow` only. There are 8 SwiftUI `.shadow` calls and no shadow tokens; `tooltipShadow` is reused for cards.
- **States.**
  - Selection is ramp 0.10 or the `AccentSelection` asset; `rowHover` 0.05; control surface/hover/pressed 0.10/0.16/0.24.
  - `BarButton` has hover fill only: no press state, no animation (`BarButton.swift:57-66`).
  - `ModalActionButtonStyle` is the only control with hover, press and an animated transition (:30-57).
  - Form focus is a neutral `border` going from 1pt to 2pt (`FormFieldChrome.swift:12-15`).
- **Motion.** `easeOut`/`easeIn` literals with `Duration` tokens; window fade plus a 0.94 scale entrance (`Interaction/PanelTransition.swift:104-115`). The global `Motion.isEnabled` / `motionScope()` switch lives in `Interaction/Motion.swift`. There are only four spring-family motions outside the scrollbar: the Settings sidebar pill, one extension toast, and a few `.snappy` calls in AI Chat, ChatWorkspace and Web Search settings.
- **Settings.** A titled `NSWindow` with `NavigationSplitView` and stock `Form.formStyle(.grouped)` (27 sites). The sidebar is a custom table with a sliding pill.

### Every glass / material use

| Recipe | Sites |
|---|---|
| **A** backdrop (`GlassEffectView`) | `Palette/RootPaletteView.swift:357-358`, `Features/Notes/UI/NotesView.swift:12-13`, `Windows/HUD/MessageHUDView.swift:61-62`, `Windows/HUD/VolumeHUDView.swift:40-41`, `Features/Camera/UI/CameraView.swift:16`, `Features/Calendar/UI/CameraPreviewView.swift:20`, `Features/QuickActions/UI/QuickActionResultView.swift:44` |
| **B** `.glassEffect(.regular)` | `DesignSystem/PopoverMenu.swift:135`; `Windows/Dialog/DialogView.swift:62-63` (+scrim); `DesignSystem/SettingsComponents.swift:265,268` (+scrim); `Features/Extensions/Settings/ExtensionSettingsEditor.swift:23-24` (same recipe again); `Extensions/UI/ExtensionActionsPanel.swift:93`; `Extensions/UI/ExtensionPickerList.swift:39`; `HotKeys/UI/ShortcutRecorderPopover.swift:71` (caret shape); `Notes/UI/NoteHeadingMenuView.swift:37`; `Notes/UI/NoteSwitcherView.swift:18`; `Dictation/UI/DictationPanel.swift:73`; `VoiceAI/UI/VoiceModeCaption.swift:65`; `AI/UI/AIChatDetailView.swift:174` (composer), `:753` (find bar), `:855`; `NotesAI/UI/NotePickerCard.swift:142`; `Agents/UI/ACPCommandPicker.swift:165` |
| **C** `frosted` | `RootPaletteView.swift:994` (action pill), `:1655` (menu circle); `Notes/UI/NotesView.swift:99,161`; `Notes/UI/NoteFormattingBar.swift:97`; `Extensions/UI/ExtensionCommandView.swift:164`; `AI/UI/AIChatSidebarView.swift:239`; `AI/UI/ChatSuggestionChips.swift:55`; `ChatWorkspace/UI/ChatWorkspaceSidebar.swift:841,947` |
| Legacy | `.ultraThinMaterial` at `AI/UI/ChatTranscriptView.swift:172`; `NSVisualEffectView(.fullScreenUI)` at `WindowManagement/UI/RoomPreviewView.swift:120-126` (desk blur, legitimate) |

There are zero uses of `GlassEffectContainer`, `glassEffectID`, glass tint, `.clear`, or `matchedGeometryEffect`.

## 2. Weaknesses against a Raycast-grade look

1. **No glass vocabulary.** About 33 call sites hand-assemble one of three recipes, so variant, tint, scrim and rim cannot be retuned centrally.
2. **The main panel reads as flat blur.** The glass has no shape of its own and is cut by a SwiftUI clip, so the system's edge highlight is lost at the corners. There is no rim stroke, and a 40% black scrim sits on top. `Colors.sheen` exists but is only used by Updates, Support and Onboarding.
3. **The tooltip is opaque.** `Tooltip.swift:48-54` fills with `windowBackgroundColor` plus a hand-made shadow, which breaks ui.md's own "no opaque fills" rule on the most-seen floating element.
4. **Glass is cancelled on overlay cards.** `AIChatDetailView.swift:855-858`, `NotePickerCard.swift:142-145` and `ACPCommandPicker.swift:165-168` each put glass over an opaque `windowSurface` with a hand shadow, copied three times.
5. **Focus is inconsistent.**
   - `FormFieldChrome` uses a neutral, thicker border.
   - `InlineArgumentFields.swift:112-118` uses `Color.accentColor` (system accent, not `Theme.Colors.accent`).
   - `SettingsEditorTextField` / `TextArea` have no focus or hover state at all (`SettingsComponents.swift:228-252`).
6. **States are thin.**
   - No press feedback on `BarButton`, `PopoverMenuRow` or the menu circle.
   - Hover fills snap everywhere except modal buttons.
   - The 0.45 disabled dim is a literal in four places (`ModalActionButtonStyle.swift:31`, `PopoverMenu.swift:428`, `SettingsComponents.swift:162`, `ChatTranscriptColors.swift:78`).
7. **Hard-coded values in DesignSystem.**
   - `SymbolPicker.swift:10-12,25,39,55` (30/26/244/14/15).
   - `AliasField` (`SettingsComponents.swift:469,489-490`: 11pt, `sm + 1`, height 24).
   - `Color.red` instead of `Colors.destructive` at `PopoverMenu.swift:375,385,396`; `.orange` at `SettingsComponents.swift:109`.
   - `InlineArgumentFields.swift:71-72,167` (magic 7/34/72/160, 8pt chevron).
   - App-wide: 11 `.font(.system(size:))`, 7 literal radii, 64 raw system colours.
8. **Two hairlines.** `Theme.Size.hairline` is 1pt (30 uses); `1/displayScale` is used in 3 places. `PopoverMenu.swift:127-128`'s own comment says the 1pt rule "reads heavy against the glass".
9. **The radius scale is ad hoc.** Five values are each restated under several names (10, 12, 16, 6, 8), and there is no concentric rule: a panel of 26 with an 8pt inset implies 18, but rows are 10.
10. **Motion has no curve tokens.** 43 ease literals; `RoomMotion` and `MenuMotion` are one-off enums.
11. **No accessibility adaptation.** Nothing reads Reduce Transparency or Increase Contrast, so separators stay at 0.10.
12. **Settings is the least Raycast-like surface.** It is stock System Settings by design, and its custom parts (`settingsOptionSegment`, `AliasField`, `SettingsFilterField`) are flat fills with no hover.

## 3. Opportunities

| # | Change | Files | Size / risk |
|---|---|---|---|
| 1 | `Theme.Glass` roles (panel, floatingControl, menu, modal, overlayCard, hud), each bundling variant, tint, scrim, rim and shape, behind one `surface(_:in:)` modifier; `frosted` folds in | Theme, about 30 call sites (Extensions keeps its own copy) | M / low if values are unchanged |
| 2 | Give `GlassEffectView` a corner radius, tint and style so the glass draws its own edge | GlassEffectView, RootPaletteView, NotesView, HUDs, Camera, QuickAction | M / medium (corner masking over light wallpaper) |
| 3 | Rim and sheen tokens: gradient hairline at `1/displayScale` on panel, dialog, menu, HUD | Theme + those surfaces | S / low |
| 4 | Lighter, tinted panel scrim | Theme:394 | S code / high visually — changes a frozen Dark literal |
| 5 | Tooltip to glass; drop the opaque fill and shadow | Tooltip.swift | S / low |
| 6 | One `overlayCard` surface plus `Theme.Shadow` tokens replacing the three copies; `ChatTranscriptView.swift:172` to `frosted` | Theme, 4 feature files | S / low |
| 7 | State kit: `Opacity.disabled`, press state on `BarButton` and menu rows, animated hover, `Colors.focusRing` shared by all field chromes | BarButton, PopoverMenu, FormFieldChrome, InlineArgumentFields, SettingsComponents | M / low-medium |
| 8 | `Theme.Motion` curve tokens absorbing `RoomMotion` / `MenuMotion` | Theme + about 50 sites | M / low |
| 9 | Radius primitives with semantic aliases and a concentric helper | Theme, InterfaceMetrics | M / medium |
| 10 | Single hairline; literal cleanup in SymbolPicker, AliasField, PopoverMenu | DesignSystem only | S / low |
| 11 | Contrast and transparency awareness inside `Colors.adaptive` | Theme | S-M / low |
| 12 | Settings polish within the rules: tokenised hover/focus on custom controls | SettingsComponents | S / low |
| 13 | Raycast-style translucent Settings (glass window background, custom cards) | 27 panes, chrome, ui.md | L / high |

Constraints on specific rows:
- **#7:** hover state must stay on the row, and menu row height must not change.
- **#9:** harnesses pin some geometry (ui.md names `callout-test`).
- **#2 and #4:** #2 changes the documented clip order and #4 a frozen Dark value; both need the owner's explicit go-ahead.

**Decision for the owner:** #13 is the only way to get visibly "more glass in Settings", and it contradicts ui.md's current Settings section ("every pane is a stock `Form`", "a main surface takes the system's material, not `glassEffect`"). Rows 1–12 improve polish without it.

**How the token system must grow:** `Theme.Glass` (roles, plus an AppKit twin for `NSGlassEffectView`), `Theme.Shadow`, `Theme.Motion`, `Theme.Opacity`, new colours (`rim`, `glassTint`, `focusRing`, scrim tiers per role, contrast-boosted ramp), primitive radii, and `InterfaceMetrics` mirrors for anything the palette scales.

## 4. Constraints an implementer must respect

- **Dark values are frozen literals.** New colours go through `ramp` / `adaptive` only; never a bare `Color.white.opacity`.
- **ui.md idea #5:** "Glass only on floating controls. The main surface is never glass", with dialogs the one exception and HUDs keeping recipe A. A glass-first redesign must be an explicit task with ui.md rewritten in the same commit.
- **Panel clip order:** scrim → `GlassEffectView` → `clipShape`, clipped once at the root.
- **`MessageHUDView.swift:60`:** `glassEffect` with nothing to lens falls back to an opaque backing, which is why HUDs use the backdrop recipe.
- **Scrolling:** no native scroll-edge effect in borderless panels; `Scrolling/EdgeDissolve.swift` and `ThinScrollbar.swift` are untouchable; mask gradients are luminance, not colour.
- **PopoverMenu:** no hand shadow, fixed width, stated row height, `LazyVStack`, no AppKit controls in rows; it lives in its own window, so glass cannot morph between pill and menu.
- **Settings:** stock grouped `Form`; `SettingsRow` for custom trailing controls; no hand-drawn header band; controls on glass lose their accent (`controlsOnGlass: false`).
- **Extensions:** anything extension-shaped stays duplicated inside `Features/Extensions/`, never in `DesignSystem/` or `Theme`.
- **Motion:** every animation goes through `motionScope()` / `Motion.duration`; panels use `followMotion()`.
- **Palette specifics:** `tooltip`, not `.help()`; dialog buttons stay matte; palette geometry reads `metrics`, not `Theme` statics.
- **Verification:** over a light desktop, with the owner's visual sign-off; Swift 6, no new warnings, lint and harnesses pass.

**Already excellent — do not break:** the alpha ramp and its discipline (the only raw white/black opacities outside masks are two extension-picker strokes and two icon shadows), `InterfaceMetrics`, armed hover, `PopoverMenu` geometry (attached-corner `SurfaceShape`, stated heights), the sidebar's sliding pill, the global Motion switch, `KeyCapChip` scales, `ModalActionButtonStyle` roles, and the edge dissolve.

## Audit: palette-shell

# Palette shell + Launcher UI: audit (read-only)

Nothing was built or rendered, so every visual judgement below is inferred from code and not confirmed on screen. Paths are relative to `/Users/superalesha/dev/opensource/launchers/tinycast/`.

## 1. How it is built today

- **Window**: borderless non-activating `NSPanel`, clear background, system shadow, AppKit `.documentWindow` open/close animation (`Tinycast/Palette/PalettePanel.swift:259-274`). Size is 750×475, or a 64pt compact bar. The compact/expanded swap is an instant `setFrame` (`Tinycast/Palette/PaletteWindowController.swift:492-498`).
- **Surface**: a default `NSGlassEffectView()` with no `cornerRadius`, `tintColor` or style (`Tinycast/DesignSystem/GlassEffectView.swift:5`). Above it sits a SwiftUI `panelScrim` (black 0.40 dark, white 0.55 light), then one `clipShape` at radius 26 (`Tinycast/Palette/RootPaletteView.swift:357-370`). There is no border, rim stroke or inner highlight.
- **Header**: transparent `safeAreaInset`, 44pt plus 10pt top padding. It holds an 18pt medium `.secondary` glyph or a bare back chevron, then a plain 20pt `TextField` with a self-drawn placeholder (`RootPaletteView.swift:693-790, 884-903`). Header pop-ups are `BarButton(.rounded)` with a rotating chevron (`Tinycast/DesignSystem/BarButton.swift:101-131`).
- **Bottom bar**: 52pt, transparent. A 36pt glass circle with a hand-drawn two-line glyph sits left; a glass capsule with the primary action plus `Actions ⌘K` sits right, both through `frosted(in:)` (`RootPaletteView.swift:931-995, 1637-1656`; `Tinycast/DesignSystem/Theme.swift:514-517`).
- **Rows**: `HStack(lg)`, 26pt icon, `.body` title, `.callout` secondary subtitle, alias chip, outline keycaps and a trailing kind label. Padding is md/sm (about 38pt tall), radius 10. Fill precedence is selection, then hover, then clear, with movement-armed hover (`Tinycast/Features/Launcher/UI/LauncherList.swift:255-352`; `Tinycast/Palette/ArmedHover.swift`).
- **Selection colour**: `AccentSelection`, a Raycast-red wash at 16% light and 24% dark; hover is white 0.05.
- **Section headers**: `.subheadline` semibold in `textSecondary` (`Tinycast/Features/Launcher/UI/SectionHeader.swift:26-30`).
- **Lead cards**: `cardFill` plus the selection/hover fill, radius 10 (`Tinycast/Features/Launcher/UI/LeadCard.swift:9-24`).
- **Menus**: a separate child `MenuPanel` window, so the glass samples the desktop. `PopoverMenu` uses `.glassEffect(.regular)` at radius 16 with rows at radius 10; the attached corner is raised to 18 to meet the button (`Tinycast/Palette/MenuPanel.swift`; `Tinycast/DesignSystem/PopoverMenu.swift:129-136, 346-432`).
- **Motion**: only the AppKit window pop, the dialog-dimming fade, the chevron rotation, the back-chevron hover and the tooltip fade. Everything else is instant. `motionScope()` and `Motion.isEnabled` gate all of it.
- **Tokens**: nearly everything goes through `@Environment(\.metrics)`, so token discipline is strong.

## 2. Weaknesses against a Raycast-grade look

1. **The main surface is glass in name only.** The 40% scrim is painted over the glass, and the corner comes from a SwiftUI clip instead of the glass's own `cornerRadius`. I would expect the specular rim and lensing to be darkened and cut at the corners, leaving a flat dark blur. That, plus the absence of any edge stroke, is likely the main reason it does not read as premium Liquid Glass.
2. **No depth hierarchy inside the panel.** Header, list and footer share one plane. Only the two footer controls are glass, and they sample an already-blurred, scrimmed surface, so they have little to refract.
3. **Lead cards and the docs disagree.** `ui.md` describes the card language as `cardFill` + `cardStroke`, but `LeadCard.swift:11-12` has no stroke. At 5% white the calculator, meeting and colour cards barely separate from the surface.
4. **Flat text hierarchy in rows.** Subtitle, alias and trailing kind label all use `.secondary` (`LauncherList.swift:303-343`); `ui.md` assigns trailing kind labels to `textTertiary`.
5. **Almost no micro-motion.** There is no transition on selection, hover, the pill label change, the action group appearing, mode push/pop, the header glyph swap or the compact/expanded resize.
6. **`.help()` is used in the palette against the project's own rule** that palette hover labels must be `tooltip`, because AppKit tooltips do not show while the app is inactive. Sites: `RootPaletteView.swift:824, 1678`; `BarButton.swift:131`; `SectionHeader.swift:22`; `CompactFavoritesRow.swift:58`. These labels probably never appear.
7. **The tooltip tile is opaque** `windowBackgroundColor` (`Tinycast/DesignSystem/Tooltip.swift:47`), the one non-translucent chip on a glass app.
8. **`EmptyResults` is unstyled and unscaled**: literal `8`, `.largeTitle`, `.callout`, `360`, with no `metrics` (`Tinycast/Palette/EmptyResults.swift:9-18`). It has about 40 call sites and offers no hint or action.
9. **Hard-coded leftovers**:
   - `HStack(spacing: 2)` at `RootPaletteView.swift:962`
   - menu glyph `3 / 14 / 1.5 / 8` at `RootPaletteView.swift:1644-1646`
   - running dot `3` at `LauncherList.swift:291`
   - `.system(size: 10)` and `cornerRadius: 6` at `CompactFavoritesRow.swift:26, 30`
   - `Color.red` instead of `Theme.Colors.destructive`, and `opacity(0.45)`, at `PopoverMenu.swift:375, 385, 396, 428`
   - `.title3` at `ColorCard.swift:20`
10. **The back control is a bare chevron** with no chip or hit-area chrome (`RootPaletteView.swift:1660-1680`); Raycast uses a small rounded tile there.
11. **The surface recipe is copy-pasted in seven places**: the palette, Notes, Camera (two), Quick Action and both HUDs. Any glass upgrade has to be repeated by hand or the siblings drift.
12. **No explicit handling of Reduce Transparency or Increase Contrast** anywhere in `Tinycast/`. The system glass may cope, but the hand-made scrim will not adapt. Not verified.

## 3. Opportunities

| # | Change | Files | Size / risk |
|---|---|---|---|
| A | Real glass panel: set `cornerRadius = panel` and move the tint into `tintColor` on `NSGlassEffectView` (thin the SwiftUI scrim), add a 1px inner rim, and expose it as one shared `panelSurface()` modifier | `DesignSystem/GlassEffectView.swift`, `DesignSystem/Theme.swift`, `Palette/RootPaletteView.swift:357-370`, plus Notes, Camera, Quick Action and both HUDs; `docs/ui.md` | M, high risk: changes the frozen Dark look and text contrast over bright wallpaper; needs owner sign-off from screenshots |
| B | Lead cards as true inset cards: `cardStroke` hairline or subtle glass, radius one step larger | `Features/Launcher/UI/LeadCard.swift`, Calculator and Meeting cards | S, low |
| C | Row hierarchy: trailing kind label to `textTertiary`, subtitle kept secondary; applied to every list | `LauncherList.swift`, Clipboard, FileSearch and Uninstall rows | S, low; must stay in sync across lists |
| D | Micro-motion: `contentTransition` on the pill label and header glyph, opacity/scale transition on the action group, 80–120ms eased hover fill, with a new `Theme.Duration` token | `RootPaletteView.swift`, `BarButton.swift`, `LauncherList.swift`, `Theme.swift` | M, medium: keystroke-path repaint cost; keep keyboard selection instant |
| E | Replace the five `.help()` calls with `.tooltip(edge: .bottom)` and make the tooltip tile glass | files listed in 2.6, `Tooltip.swift` | S, low; glass must be a background, since a wrapper swallows the tooltip |
| F | Empty state on tokens with glyph tile, title, hint and optional keycap | `Palette/EmptyResults.swift` | S, low; many call sites, all strings localised in eight languages |
| G | Back button as a `controlSurface` rounded chip with hover and pressed states | `RootPaletteView.swift:1660-1680` | S, low; keep `headerIconSlot` width so the query's x position does not move |
| H | Footer polish: `GlassEffectContainer` around the bar controls, `controlPressed` state on `BarButton`, tokenise the leftovers in 2.9 | `RootPaletteView.swift`, `BarButton.swift`, `PopoverMenu.swift`, `CompactFavoritesRow.swift`, `Theme.swift`, `InterfaceMetrics.swift` | S–M, low; new tokens must pass `interface-size-test` |
| I | Animated compact/expanded height | `PaletteWindowController.swift:492-498` | M, high risk: sole frame owner, the top edge must not drift, and typing must not lag. Lowest priority |

Suggested order: A (as a toggleable prototype for screenshot approval), then B, C, E, G and F, then D and H. Skip I unless asked.

## 4. Constraints an implementer must respect

- **Dark values are frozen**, and the root order of scrim over glass with the clip last is a stated invariant (`docs/ui.md`, "Non-negotiable invariants"). Option A is an explicit change to Dark, so it needs the owner's approval and a `ui.md` update in the same commit.
- **Colours** go only through `Theme.Colors.ramp` / `adaptive`. No bare `Color.white.opacity`, no grays, no opaque fills.
- **Bars and edges**: no hard dividers between list and bars, no native scroll edge effect, and `EdgeDissolve.swift` and `ThinScrollbar.swift` are off-limits. Glass inside the panel must not break the mask-based dissolve.
- **Shapes**: the footer action group stays a `Capsule`, corners are always `.continuous`, `menuPanel 16 − sm 6 = menuRow 10` stays concentric, and menus keep fixed widths and no hand-made shadow.
- **Scaling**: views read `@Environment(\.metrics)`. New tokens go in `Theme` and are mirrored in `InterfaceMetrics`; screen-relative lengths do not scale.
- **Motion**: only through `motionScope()` and `Motion.duration`, never a per-site settings check; honour Reduce Motion.
- **Row grammar**: fill precedence, insets and header style change for all lists or none. Hover state stays on the row and stays movement-armed.
- **Search field**: never mounted conditionally, no `prompt:`, and header metrics are identical in compact and expanded states. `PaletteWindowController` alone owns the frame (`sizingOptions = []`).
- **Selection** is the red `AccentSelection` wash at the owner's request; do not neutralise it.
- **Extensions**: nothing extension-specific may land in `DesignSystem/` or `Theme`.
- **Presentation**: menus stay child windows. No `NSAlert` or system popovers. Palette hover labels use `tooltip`.
- **Process**: restyle from screenshots over a light desktop, do not change interaction, and run `./Scripts/run-tests.sh`, `./Scripts/lint.sh` and `sync-strings.sh` with all eight languages for any text.

**Already excellent, do not break**: movement-armed hover, the selection-follow scroll invariant, the edge dissolve, floating transparent bars, concentric menu geometry, child-window glass menus, the Interface Size scaling system, icon tile artwork, per-row hover isolation, and the IME-safe placeholder.

## Audit: settings

# Settings surface audit (read-only; nothing built or run, so visual claims are inferred from code)

Paths relative to `/Users/superalesha/dev/opensource/launchers/tinycast/Tinycast/`.

## 1. How it is built today
- **Window**: titled, resizable `NSWindow` with `.fullSizeContentView`, 900×700 (`Windows/AppWindowController.swift:106-140`, `DesignSystem/Theme.swift:189`). `Features/Settings/SettingsWindowChrome.swift:6-16` restores the system titlebar band (unified toolbar, no separator, not background-draggable). No material or background colour is set, so the window is the stock opaque one.
- **Shell**: one `NavigationSplitView`, sidebar fixed at 218, Back/Forward `ControlGroup`, pane title in the titlebar (`Features/Settings/SettingsRootView.swift:8-30`).
- **Sidebar**: `NSTableView` with one Core Animation pill: radius 8, 0.5pt edge, ramp fills 0.08/0.12, spring 0.22s with no bounce, 0.12s hover wash (`SettingsSidebarTable.swift:255-305, 351-377`; tokens in `DesignSystem/RaycastPalette.swift:42-70`). Rows are 32pt with 24pt `TileArtwork` tiles. Groups are 12pt gaps whose titles only VoiceOver gets (`SettingsSidebarView.swift:41-43`).
- **Detail**: a hard `switch` over 24 panes with no transition and a one-frame defer (`SettingsDetailView.swift:11-60`). Every pane is a stock `Form.formStyle(.grouped)`; `.scrollContentBackground(.hidden)` and the red tint are applied once (`SettingsEditorPresenter.swift:370, 400`).
- **Components** (`DesignSystem/SettingsComponents.swift`): `SettingsRow` (27-65), `AliasField` and `ShortcutRecorder` at 24pt with `cardFill` + 1pt `cardStroke`, radius 6; `settingsOptionSegment` at 28pt, radius 8 (146-158).
- **Editors**: child `NSPanel`, radius 26, `panelScrim` + `glassEffect(.regular)` (254-272), with a dimming blocker that fades 0.12/0.10s.
- **Motion**: pill spring, hover wash, search reveal and pulse (`SettingsScrollTarget.swift:92-104`). Across every feature `Settings/` folder there are 4 animation sites and 2 `onHover`.
- **Commit 487a4fc4** changed the sidebar table and pill, `TileArtwork` (469 lines), the pane defer and off-main permission polling. It did not touch pane layout, window material, tables or detail panes.

## 2. Weaknesses against a Raycast-grade look
1. **The only glass is the system sidebar/titlebar and the editor panels.** The detail column is opaque window background with System Settings cards, so Settings reads as a different product from the palette. `docs/ui.md` states this as a deliberate decision, which the owner's request overturns.
2. **Information architecture**: 24 flat panes in four unlabelled groups. Launcher items are spread over 7 panes as Form rows of alias, recorder and checkbox, with no column headers, sorting, row selection or inspector. Raycast uses one dense table plus a detail pane.
3. **The Shortcuts pane pages a `Form` with "Show More (n)"**, a literal 96pt kind column and `Color.clear` spacers (`Features/ShortcutsOverview/Settings/ShortcutsSettingsView.swift:41-44, 111-120`).
4. **System dialogs and popovers appear inside Settings, against the AGENTS.md invariant.** I found no exemption in the docs.
   - `.confirmationDialog`: `Panes/GeneralSettingsView.swift:150`, `Clipboard/Settings/ClipboardSettingsView.swift:67`, `MCP/Settings/MCPSettingsSection.swift:55`, `AI/Settings/AIProvidersPanel.swift:104`.
   - `.alert`: `WindowManagement/Settings/WindowManagementSettingsView.swift:51`.
   - `.popover`: 9 sites, including `WindowLayoutInspector.swift:71`, `WindowLayoutEntryPicker.swift:30, 64`, `VoiceModelRow.swift:42`, `ExtensionsSettingsView.swift:720`.
5. **Raw colours**: about 50 `.foregroundStyle(.orange/.green/.red)` sites, although `Theme.Colors.warning/success/destructive` exist. Status is plain coloured text with no badge.
6. **Magic numbers**:
   - Height 24 in four places (`SettingsComponents.swift:490`, `HotKeys/UI/ShortcutRecorder.swift:29`, Shortcuts pane 115/120).
   - Font size 11 (`SettingsComponents.swift:469`).
   - Disabled opacity 0.45 in three places.
   - `Color.primary.opacity(0.08)` (`ShortcutRecorder.swift:91`).
   - Window-mode preview 135×80 (`GeneralSettingsView.swift:179`).
   - Literal panel sizes 620×560, 620×540, 340×360, 220×240.
   - `.black.opacity(0.35)` shadow and icon size 88 in `Windows/About/AboutView.swift`.
7. **Permissions pane**: four copy-pasted 30-line sections whose headers repeat the row title, mixing real app icons with bare SF Symbols (`Panes/PermissionsSettingsView.swift:16-154`).
8. **No pane transition**: an instant swap after a build of up to 190 ms.
9. **No hover or pressed states on custom controls**: `settingsOptionSegment` has a selected fill only, and Window Mode signals selection by saturation alone (`GeneralSettingsView.swift:194-218`). `controlHover` and `controlPressed` exist but are unused here.
10. **No pane hero**: feature panes open on a toggle row with a 30pt tile (`SettingsComponents.swift:6-24`).
11. **Doc drift**: `ui.md` says `settingsSidebar 215`; `Theme.swift:191` is 218.

Raycast's own Settings is not especially translucent; its signature is structure (top tabs, dense table, inspector). "Like Raycast" and "more glass" are two separate workstreams.

## 3. Opportunities
| # | Change | Files | Size / risk |
|---|---|---|---|
| A | Translucent window: behind-window material plus a new adaptive scrim token under the whole window. Forms already hide their scroll background. | `SettingsWindowChrome.swift`, `Theme.swift` | S–M / **M**: legibility over light wallpaper; system card fills may go muddy; needs owner sign-off by eye |
| B | Let the system glass sidebar refract something (follows from A). Add visible group headers and a version footer. | `SettingsSidebarView.swift:41-43`, `SettingsSidebarTable.swift:126-131`, `RaycastPalette.swift` | S / low |
| C | Pane hero: 40pt tile, title, one-line description, master switch. It propagates through `FeatureSwitchSection`. | `SettingsComponents.swift:6-24, 274-309`, `LauncherItemsSection.swift:4-26` | S–M / low; new strings in 8 languages |
| D | Token hygiene: inline-control height, disabled opacity, semantic colours, and one `SettingsStatusBadge` capsule. | `Theme.swift`, `SettingsComponents.swift`, ~25 pane files | M mechanical / low |
| E | Rebuild Permissions as one section driven by a row table, with tiles, badges and an accent button when access is missing. | `PermissionsSettingsView.swift` | S / low |
| F | Replace system dialogs with `DialogController`, and popovers with `settingsEditorPanel` or the in-app menu. | the files in §2.4 | M / low–M |
| G | Motion: opacity crossfade on pane swap, hover/pressed plus a selection ring on segments and Window Mode, symbol transitions on status changes. | `SettingsDetailView.swift`, `SettingsComponents.swift:146-158`, `GeneralSettingsView.swift` | S / low–M: a crossfade keeps two panes alive |
| H | Shortcuts pane on a real table: column headers, no paging, reusing `LauncherItemsTable`. | `ShortcutsSettingsView.swift`, `Launcher/Settings/LauncherItemsTable.swift` | M / M |
| I | Raycast-style unified items table with a right inspector, merging the launcher panes. | `SettingsTab.swift`, `SettingsDetailView.swift`, `SettingsSearchCatalog.swift`, `SettingsAnchor.swift`, launcher settings, tests, lint script | **L / high** |
| J | Custom card look replacing the grouped `Form`. | 40+ panes | **L / high**; contradicts `ui.md`; I would defer it |
| K | Editor panels: exit fade and size tokens. | `SettingsEditorPresenter.swift:321-333` | S / low |

Suggested order: D, E, F, C, G, B, then A as a prototype, then H. I and J only on an explicit decision.

## 4. Constraints an implementer must respect
- **Colour**: Dark values are frozen. New colours go through `Theme.Colors.ramp/adaptive`; no bare `Color.white.opacity`.
- **Glass**: floating controls only. "A main surface takes the system's material, not `glassEffect`", and never a hand-drawn header band. Settings keeps the system titlebar.
- **Window chrome**: it installs before the content mounts (`AppWindowController.swift:126-129`). `AppWindowController` is shared with AI Chat, Onboarding, Updates and Support, so Settings-only changes belong in `SettingsWindowChrome`.
- **Panes**: stock grouped `Form`; rows are stock controls; `SettingsRow` for a custom trailing control (`LabeledContent` swallows recorder taps); `.settingsEnabled`, never bare `.disabled`.
- **Form limits**: a `Form` realises every row, so long lists must be an `NSTableView`. No lazy stack around AppKit controls. `.listRowBackground` is a no-op, and `.background` paints ragged content boxes.
- **Sidebar**: stays an `NSTableView` with one CA pill and non-floating group rows. `.toolbar(removing:)` goes before the column width. Do not return to `NSSplitViewController`, and do not use `TabView` (it re-hosts and breaks the recorder).
- **Search**: `SettingsSearchCatalog` is hand-written. A catalog entry and its anchor marker move together; `Scripts/check-settings-search.js` and `Tests/settings-history-test.swift` enforce it. `SettingsTab.ownedCommands` is the only statement of pane ownership.
- **Motion**: only through `motionScope()` and `Motion.duration`; no site reads the setting itself.
- **Dialogs**: no `NSAlert` or system popovers. `.help()` is allowed in Settings.
- **Extensions**: their settings visuals stay inside `Features/Extensions/` and are never lifted into `DesignSystem/`.
- **Off-limits**: `EdgeDissolve.swift` and `ThinScrollbar.swift`.
- **Scaling**: Settings never scales with Interface Size, but shared `DesignSystem` components must read `\.metrics`.
- **Process**: strings localized in 8 languages plus `sync-strings.sh`; a new preference needs a `SettingsFileKey`; one-line comments; Swift 6; `run-tests.sh` and `lint.sh`; docs fixed in the same commit; visual sign-off by the owner over a light desktop.

**Already excellent, do not break**:
- the render-server pill spring and hover wash;
- search with reveal and pulse, and Back/Forward history;
- `TileArtwork` tiles;
- the glass editor-panel stack with drag hand-off;
- the performance work: pane defer, hosted table cells, off-main permission polling.

## Audit: windows-overlays

# windows-overlays surface audit (read-only)

Paths are relative to `/Users/superalesha/dev/opensource/launchers/tinycast/Tinycast/`. Nothing was built or run, so every visual claim is from code and still needs sign-off over a light wallpaper.

## 1. How it is built today

- **Dialog** — `panelScrim` under one `.glassEffect(.regular)` in `RoundedRectangle(panel 26)` (`Windows/Dialog/DialogView.swift:60-63`). The hosting layer is clipped and AppKit draws the shadow (`DialogPanel.swift:34-41`). Buttons are matte capsules with rest/hover/pressed ramps and a 0.12s ease (`DesignSystem/ModalActionButtonStyle.swift:29-56`). Entrance is `.documentWindow`.
- **HUDs** — scrim → `GlassEffectView()` → clip, not SwiftUI glass (`HUD/VolumeHUDView.swift:40-42`, `MessageHUDView.swift:61-63`). The pill adds a tone glow and gradient rim (`:67-88`). `HUDPresenter` fades 0.18/0.12 (`:39,47`). Only the volume box has `panelEntrance()` (0.94 scale).
- **Tooltip** — opaque `windowBackgroundColor` plus `controlSurface`, hand-made shadow, radius 8, 0.4s delay (`DesignSystem/Tooltip.swift:44-59`). It is an in-window overlay.
- **Dictation** — a 144×44 `.glassEffect(.regular, in: .capsule)` (`Features/Dictation/UI/DictationPanel.swift:72-73`). The mode chip is a separate glass capsule panel (`Features/VoiceAI/UI/VoiceModeCaption.swift:55-65`).
- **Notes** — scrim → glass → 26 clip (`Features/Notes/UI/NotesView.swift:12-14`), with `frosted` capsules (`:99,161`, `NoteFormattingBar.swift:97`). The switcher and heading menu are glass child panels at `menuPanel 16` (`NoteSwitcherView.swift:18`, `NoteHeadingMenuView.swift:37`).
- **Recorder callout** — one glass `CalloutShape` path, scale 0.5→1 plus opacity (`Features/HotKeys/UI/ShortcutRecorderPopover.swift:71-72,141-144`).
- **Window switcher** — a palette screen on the shared row grammar with `edgeDissolve` (`Features/WindowSwitcher/UI/WindowSwitchList.swift:31,46-50`).
- **Onboarding** — a titled opaque window with a transparent titlebar (`Windows/AppWindowController.swift:107-120`), a `sheen` gradient and hand-drawn `OnboardingCard` (`Features/Onboarding/OnboardingCard.swift:10-17`).
- **About and Shortcuts** — stock grouped `Form`s inside Settings.

## 2. Weaknesses

1. **Onboarding is the flattest surface, and it is the first impression.**
   - Opaque window, stock `.borderedProminent` and `.roundedBorder` controls (`OnboardingView.swift:199,254-260`).
   - Raw `.blue/.orange/.green` instead of the Raycast hues (`:116-118,345-349`).
   - Literals: `.system(size: 30)`, 60, 7, 150, `duration: 0.2` (`:48,78-83,200,227`).
   - A step change is a bare cross-fade while the window height jumps with `animate: false` (`AppWindowController.swift:92`).
   - Copy still says "Tinycast" (`:90,100,124,147`) while About shows Redcast.
2. **Tooltip is an opaque grey tile beside glass controls.** Being in-window, it clips at window edges, which is why `NoteFormattingBar.swift:130,175` carry alignment workarounds.
3. **Volume HUD ignores Interface Size (probable bug).** `VolumeHUDView.swift:8-42` reads `Theme.*`, but its window is sized from scaled metrics (`VolumeHUDController.swift:25-28`), so box and window disagree off the default size.
4. **HUD motion is uneven.**
   - The pill has no entrance scale.
   - Each `show` installs a new hosting view (`HUDPresenter.swift:28-33`), so spinner → result is a hard cut.
   - `HUDPanel.swift:13-14` says "no elevation" but sets `hasShadow = true`.
5. **Dictation capsule is anonymous.**
   - Neutral glass with no state tint or glyph.
   - Listening → transcribing is an `if` swap with no transition (`DictationPanel.swift:58-70`).
   - Magic numbers at `:25-31,43-47,143`.
   - The mode chip is a plain `NSPanel` that pops in with no animation, with `gap = 8` and `.callout.medium` literals (`VoiceModeCaption.swift:7,61`).
6. **Dead tooltips in Notes.** `.help()` on the titlebar actions and switcher row buttons (`NotesView.swift:175`, `NoteSwitcherView.swift:227`) never shows in a non-activating panel, per `docs/ui.md`. The formatting bar already uses `.tooltip`. Switcher row buttons also have no hover state.
7. **Recorder field bypasses Theme.**
   - Height 24 is repeated in three places (`ShortcutRecorder.swift:29`, `ShortcutsSettingsView.swift:115,120`).
   - `Color.primary.opacity(0.08)`, `size: 11`, `duration: 0.12` (`ShortcutRecorder.swift:49,91,105`).
   - `.orange` instead of `Theme.Colors.warning` (`:72`, `ShortcutRecorderPopover.swift:77`).
   - Its caps are a third keycap style beside `KeyCapChip`.
8. **Dialog details.**
   - The glyph tile is a flat tint with literals 0.12/0.18 (`DialogView.swift:15-16`).
   - Buttons have no press scale.
   - There is no Tab traversal or focus ring between actions.
9. **About is plain.** Literal shadow `.black.opacity(0.35)` and sizes 88/13/14 (`Windows/About/AboutView.swift:24,53,168,175`).
10. **Window switcher is text-only.** No window thumbnails and no app grouping.
11. **Doc drift.** `docs/ui.md` says `noteTitlebar 44` in a titlebar accessory; the code is 52 and drawn inline (`Theme.swift:82`, `NotesView.swift:23-32`).

## 3. Opportunities

| # | Change | Files | Size | Risk |
|---|---|---|---|---|
| A | Onboarding restyle: glass or `Form`-grade cards, Raycast hue tiles via `GlyphTile`, `modalAction` buttons, directional step transition, animated height, tokens | `Features/Onboarding/*`, `Theme.swift`, maybe `AppWindowController.fitContent` | L | Medium (window sizing loop at `OnboardingView.swift:32-37`) |
| B | Glass tooltip (`.glassEffect` in the radius-8 shape, drop the manual shadow) | `DesignSystem/Tooltip.swift` | S | Medium (shared by palette, dialogs and Notes; glass clips its content) |
| C | Fix volume HUD metrics | `VolumeHUDView.swift` | S | Low |
| D | HUD motion: entrance scale on the pill, cross-fade content on replace, settle the shadow question | `HUDPresenter.swift`, `MessageHUDView.swift`, `HUDPanel.swift` | M | Medium (first-HUD sizing invariant) |
| E | Dictation polish: phase cross-fade, accent tint while listening, tokens, animated mode chip | `DictationPanel.swift`, `VoiceModeCaption.swift`, `Theme.swift` | M | Low-medium (key handling in `sendEvent` must stay) |
| F | Notes: swap `.help` for `.tooltip`, add hover to switcher row buttons | `NotesView.swift`, `NoteSwitcherView.swift` | S | Low |
| G | Recorder tokens and one keycap language | `ShortcutRecorder.swift`, `ShortcutsSettingsView.swift`, `Theme.swift` | S | Low (`callout-test` pins the width) |
| H | Dialog polish: gradient or glass glyph tile, press scale, optional Tab focus | `DialogView.swift`, `ModalActionButtonStyle.swift`, `DialogPanel.swift` | S-M | Medium (the style is shared with Settings editors, camera and Quick Actions) |
| I | About hero: tokens, a glass or sheen backdrop | `AboutView.swift` | S | Low |
| J | Window switcher thumbnails | `Features/WindowSwitcher/*` | L | High (Screen Recording permission, performance) — product decision |

Suggested order: C, F, G first (cheap and correct), then A, B, D, E for the visible gain.

## 4. Constraints

- **Glass policy is documented.** `docs/ui.md` says glass is for floating controls with dialogs the one exception, HUDs keep the scrim recipe, and a titled window takes the system material. More glass is a deliberate policy change; update `docs/ui.md` in the same commit.
- **A tested dead end.** `MessageHUDView.swift:60` notes SwiftUI glass on the pill "falls back to an opaque backing". The dictation capsule uses it in its own window, so check visually before converting HUDs.
- **Dark colour branches are frozen.** New colours go through `Theme.Colors.ramp/adaptive`, with no bare `Color.white.opacity`. New numbers become `Theme` tokens.
- **Interface Size.** Dialogs and HUDs read `@Environment(\.metrics)`. Onboarding, About and Notes never scale.
- **Motion.** Every hosting root keeps `motionScope()`, panels use `AnimatedPanel.followMotion()`, AppKit durations go through `Motion.duration`.
- **Dialogs.** Keep the three axes (icon, tone, role), Cancel leading, ↵/Esc via `sendEvent`, and no `NSAlert`. The continuation resumes before `orderOut`.
- **HUDPresenter.** Size from a local, never `host.frame`. A new HUD means a new presenter.
- **Shared menu radii.** `Radius.menuPanel` and `menuRow` serve the ⌘K menu, the callout and the Notes switcher. `shortcutPopover.width` is pinned by `Tests/callout-test.swift`.
- **Off-limits.** `EdgeDissolve.swift` and `ThinScrollbar.swift`. No native scroll edge effect in borderless panels. Glyphs go through `SymbolImage`.
- **Strings.** Any change needs `./Scripts/sync-strings.sh` and all eight languages.
- **Comments.** One line, why-only.

## Already excellent — do not break

- The dialog's three-axis model and `ModalActionButtonStyle` role colours.
- The pill's tone glow and rim, and its hover-to-cancel progress state.
- The single-path glass callout with pure `CalloutPlacement`.
- The Notes formatting capsule that grows out of its round button, and the traffic-light seating.
- `HUDPresenter` replace/extend semantics, and the volume bar sliding in place.

## Audit: ai-chat

# ai-chat surface audit (read-only, from code; nothing was built or run, so visual claims are inferred)

Root: `/Users/superalesha/dev/opensource/launchers/tinycast/Tinycast/Features/` (paths below are relative to it). `ReasoningReplay` is model-only and `QuickAITools` has no visuals of its own.

## 1. How it is built today

- **Window**: titled `NSWindow` with a three-item `NSSplitViewController`: system-material sidebar, plain detail pane, inspector (`ChatWorkspace/UI/ChatWorkspaceSplitViewController.swift:13-31`). Unified toolbar on the system band; ⌘K is an `NSMenu` (`AI/UI/AIChatWindowChrome.swift:55-63,155-163`).
- **Composer**: one `.glassEffect(.regular)` at `Radius.dialog` 20, on a background layer (`AI/UI/AIChatDetailView.swift:173-176`). It is stacked under the transcript, not floated (`:38-39`). Controls are 28pt, bare at rest, `controlSurface` on hover at `barControl` 8 (`:319-330`). Send is a red disc with a `symbolEffect(.replace)` swap (`:230-250`).
- **Transcript**: non-lazy `VStack`, 960pt reading column (`AI/UI/ChatTranscriptView.swift:46,81`). The user bubble is a vermilion wash plus edge at `radius.row` 10 (`ChatWorkspace/UI/ChatTranscriptColors.swift:44-54`); replies are bare. Footer actions fade in on hover over 0.12s (`ChatTranscriptView.swift:218-241`). Code blocks are drawn in `NSTextView.drawBackground` with `cardFill`/`cardStroke` at `codeBlock` 14 (`AI/UI/ChatMarkdownText.swift:224-241`).
- **Chips**: suggestion and source chips are `frosted(in: Capsule())` (`AI/UI/ChatSuggestionChips.swift:46-58`); attachment chips are matte.
- **Sidebar**: `List(.sidebar)` with custom row fills in the order selection, open (vermilion), hover (`ChatWorkspace/UI/ChatWorkspaceSidebar.swift:426-446`). Section headers are hue-tinted (`:321-342`). The search field and bulk-selection bar are frosted capsules (`:932`, `:838`).
- **Inspector**: matte cards (`chatSettingsCard` + `cardStroke`, radius 10), custom dropdowns, a hand-drawn switch (`ChatWorkspace/UI/ChatSettingsSidebar.swift:219-229,251-305`).
- **Usage**: a Settings `Section` of `SettingsRow`s plus a hand-rolled 28pt bar strip (`UsageDashboard/Settings/UsageSection.swift:330-369`).
- **Palette surfaces** (Quick AI, Chat History, Agent Sessions) follow the shared row grammar: `edgeDissolve`, `thinScrollbar`, `armedHover` (`AI/UI/ChatHistoryView.swift:76-127`, `AgentSessions/UI/AgentSessionsList.swift:156-193`).
- **Motion**: `Duration.hover` and `chatFooter` are 0.12s; the rest is ad-hoc `.snappy`.

## 2. Weaknesses against a Raycast-grade look

1. **The composer's glass has nothing behind it.** It sits on the opaque window background and the transcript never scrolls under it, so it likely reads as a grey rounded box. This is the largest gap, and it is a documented choice (`docs/ui.md:469-470`).
2. **Glass is applied inconsistently.**
   - Jump to Latest is the only `.ultraThinMaterial` in the app, with a manual stroke (`ChatTranscriptView.swift:172-173`).
   - `ACPCommandCard` is glass over solid `windowSurface` with a hand-tuned shadow (`Agents/UI/ACPCommandPicker.swift:166-169`), against the "no hand-tuned shadow" rule.
   - `GlassEffectContainer` and `glassEffectID` are used nowhere, so chips and composer cannot merge or morph.
3. **Three control dialects share one window.** Custom `ChatSwitch` (`ChatTranscriptColors.swift:58-90`), native `.checkbox` (`ChatSettingsSidebar.swift:340`), `.roundedBorder` field (`ChatWorkspace/UI/ChatFolderEditor.swift:39`), `.link` button (`Agents/UI/ChatQueue.swift`).
4. **Values bypass Theme.**
   - Switch `32×18`, `Color.white`, `.opacity(0.45)` (`ChatTranscriptColors.swift:71-78`).
   - Usage ring `26` / `lineWidth 3` (`ChatSettingsSidebar.swift:363-369`), although a tokenised `ContextRing` exists (`AIChatDetailView.swift:771-785`).
   - `.system(size: 9)` (`AI/UI/ChatComposerChips.swift:54`); `lineWidth 1.5` and `.white` (`ChatWorkspace/UI/ChatMessageActions.swift:111,118`); `lineWidth 2` / `padding(-3)` (`ChatFolderEditor.swift:94-95`).
   - Alpha `0.16` instead of `hue.wash` (`ChatTranscriptColors.swift:13`); `Color.accentColor` instead of `Theme.Colors.accent` (`AIChatDetailView.swift:407,446`).
5. **Two tile looks.** `ChatFolderTile` is white on a flat fill (`ChatWorkspaceSidebar.swift:583-598`) and is reused for the agent in the model chip (`ChatWorkspace/UI/ChatModelChip.swift:25`). `AgentChatHeader` uses the lit `GlyphTile`. `docs/ui.md:326` says "never white on flat".
6. **The card recipe is copy-pasted with drifting radii.** Card 10 in `MarkdownCodeView`, `MarkdownTableView` and `ChatToolContentView`; 14 in the text view; the inspector card appears twice (`ChatSettingsSidebar.swift:219-229,426-433`). The session preview header has a fill and no stroke (`AgentSessions/UI/AgentSessionPreview.swift:61-63`).
7. **Motion is thin.**
   - A new message has no arrival transition.
   - Streaming shows only a small `ProgressView` (`ChatTranscriptView.swift:256-259`).
   - Expanding sections fade only.
   - Sidebar hover is not animated and has no pressed state.
   - `.snappy` is not a token (`AIChatDetailView.swift:73-74,177`).
8. **The empty state is the weakest screen.** A grey `sparkles`, "Ask anything" and a stock `Button("Configure AI")` (`AI/UI/AIEmptyState.swift:12-33`).
9. **The usage chart is dated.** Grey bars, no axis, values only in `.help`; Swift Charts is imported nowhere in the app.
10. **UX friction.**
    - The model chip only toggles the inspector (`ChatModelChip.swift:11`), so changing model is two or more clicks away from the composer.
    - `slider.horizontal.3` means Actions, AI Settings, Chat Settings and Folder Settings.
    - The queue strip and editing banner are unstyled text rows.
11. **Unreachable upstream code and a stale doc.** About 450 lines in `AIChatDetailView.swift` are never instantiated: `WebSearchPill`, `AIAgentPicker`, `AIAgentOptionPickers`, `AIModelPicker`, `AIReasoningPicker`, `ContextGauge`. `showsContext` is therefore never set, so `ContextCard` never shows. `AIChatSidebarView` and `AIChatSplitViewController` are also unused. `docs/ui.md:474-477` still describes the context card as live.

## 3. Opportunities

| # | Change | Files | Size / risk |
|---|---|---|---|
| A | Float the composer over the transcript on the window surface: bottom content margin, system soft scroll-edge effect (allowed in titled windows, `ui.md:47`), chips and composer in one `GlassEffectContainer` | `AIChatDetailView.swift`, `ChatTranscriptView.swift` (tail maths `:88-96`, `TranscriptScrollChrome`), `ACPCommandPicker.swift`, NotesAI picker, `docs/ui.md` | L / high. Reverses a stated decision, so needs the owner's yes; touches tail-follow and find scrolling |
| B | Glass tidy: Jump to Latest becomes `frosted(in: Circle())`; drop the solid-plus-shadow under cards | `ChatTranscriptView.swift`, `ACPCommandPicker.swift` | S / low |
| C | Inspector pass: one card modifier, one switch (tinted native, or tokenised), one field style, shared ring | `ChatSettingsSidebar.swift`, `ChatTranscriptColors.swift`, `ChatFolderEditor.swift`, `ChatWorkspaceTheme.swift` | M / low |
| D | Empty-state hero: agent or model tile, greeting, starter chips (reuse `chatChip`) | `AIEmptyState.swift`, `Localizable.xcstrings` (8 languages) | S–M / low. Shared with the palette, so it must use `metrics` |
| E | Transcript polish: `Radius.chatBubble` (about 16–18), one code/tool/table card at `codeBlock`, message arrival transition, a livelier "Thinking…" | `ChatTranscriptView.swift`, `ChatTranscriptColors.swift`, `MarkdownCodeView.swift`, `MarkdownTableView.swift`, `Agents/UI/ChatToolContentView.swift`, `Theme.swift`, `InterfaceMetrics.swift` | M / medium. Equatable rows and a non-lazy stack are perf-sensitive |
| F | Token sweep of item 4; `ChatFolderTile` drawn through `GlyphTile`/`TileArtwork` | files in item 4, `ChatWorkspaceTheme.swift` | S / low. Snapshots change |
| G | Usage on Swift Charts (Apple framework): hover selection, axis, stat tiles for tokens, cost and replies, per-model share bars (`aiUsageBar 110` already exists) | `UsageSection.swift`, `Theme.swift` | M / low |
| H | Model chip opens the model menu, with "Chat Settings…" as a row | `ChatModelChip.swift`, `ChatSettingsSidebar.swift` (reuse `ChatSettingsDropdown`), `ChatWorkspaceKeys.swift` | S–M / medium. A behaviour change, so ask first |
| I | Sidebar hover animation and pressed state; queue and editing banner as chips inside the composer glass | `ChatWorkspaceSidebar.swift`, `ChatQueue.swift`, `ChatMessageActions.swift` | S / low |

## 4. Constraints for an implementer

- **Dark values are frozen.** New colours go through `ramp`/`adaptive`, never bare `Color.white.opacity`. Chat tokens live in `ChatWorkspaceTheme.swift`.
- **Glass is for floating controls only.** No hand-tuned shadow on glass. The window keeps the system titlebar band and system sidebar material (`ui.md:466-487,837`).
- **`EdgeDissolve.swift` and `ThinScrollbar.swift` are off-limits.** The window surface omits them on purpose.
- **`ChatTranscriptView` and `AIEmptyState` are shared** with Quick AI, the history preview and the Agent Sessions preview. Read `@Environment(\.metrics)` and gate window-only changes on `surface == .window`. A new scaled token needs an `InterfaceMetrics` entry, and `interface-size-test` pins those.
- **Motion**: every animation runs under `motionScope()`; no site checks the setting. Add tokens to `Theme.Duration`.
- **Type and symbols**: system text styles only, continuous corners, `SymbolImage` for catalog symbols.
- **Tooltips**: `.help()` is fine in the window; the palette needs `tooltip`. `chatToolTip` exists because `.help` cost 130 environment nodes each.
- **Fork hygiene**: upstream files (`AIChatDetailView`, `ChatTranscriptView`, `AIChatWindowChrome`) take one-line `// Fork:` hooks, and new code belongs in `ChatWorkspace/`. I read the unused pickers as kept for upstream merges; that is my inference, not a documented rule.
- **Tests that pin this surface**: `chat-workspace-test` (hue ink at 4.5:1 or better), `chat-workspace-snapshots`, `chat-markdown-test`, `colorful-icons-test`, `chat-memory-harness`.
- **Also**: `Features/*/Model` may not import SwiftUI; strings need eight languages plus `sync-strings.sh`; comments are one line and explain why; a restyle must not change behaviour (`ui.md:1022`).

**Already excellent, keep as is**: tail-follow and Jump to Latest logic, find highlighting, the hue system with contrast tests, branch guides and folder hairline, the native split view and toolbar, the quiet one-row composer with a single red Send, the footer laid out at rest so hover never reflows, and code-language pills.

## Audit: feature-screens

# Feature screens: cross-screen consistency audit (read-only)

Paths are relative to `/Users/superalesha/dev/opensource/launchers/tinycast/Tinycast/`. Nothing was built or run, so every visual claim comes from reading code.

## 1. How it is built today

- **Surface.** No screen paints a background; all sit on the root `panelScrim` over `GlassEffectView`. None of these features calls `glassEffect` or `frosted`. Only `Camera/UI/CameraView.swift:15-17` restates the panel recipe, at `Radius.dialog`.
- **List scaffold.** 13 lists repeat one scaffold: `LazyVStack(spacing: 0)`, padding `md`/`xs`/`md`, `.hideNativeScrollers()`, `.scrollOriginAnchor()`, `.edgeDissolve()`, `.thinScrollbar()`, `.scrollFollowsSelection` (e.g. `Features/Clipboard/UI/ClipboardView.swift:55-95`).
- **Row grammar.** `HStack(lg)`, a 26pt `resultRowIcon` slot, `rowTitle`, padding `md`/`sm`, `Radius.row`, fill selection → hover → clear, `.armedHover` (`ClipboardView.swift:140-169`). The `fill` computed property is pasted into 25 files.
- **Split screens.** Seven screens (Clipboard, FileSearch, Snippets, Quicklinks, ExtensionStore, CustomCommands, DictationHistory) hand-write list at `clipboardListWidth` 290 + a `separator` hairline + preview (`Features/Snippets/UI/SnippetsScreen.swift:86-87`).
- **Preview panes.** Stage on top, a private "Information" block of label/value rows below. That block is re-implemented seven times.
- **Detail pages.** Dictionary and MeetingDetails use `xxl` gutters, a `calcResult` title, and tertiary section titles over a hairline (`Features/Dictionary/UI/DictionaryEntryView.swift:89-98`, `Features/Calendar/UI/MeetingDetailsView.swift:71-81`).
- **Cards.** `.leadCard(selected:)` (`Features/Launcher/UI/LeadCard.swift:9-24`) carries the calculator and meeting cards.
- **Empty states.** One shared `Palette/EmptyResults.swift` (largeTitle hierarchical glyph, text, optional detail), about 40 call sites.
- **Motion.** Almost none: the emoji cell's hover fade (`Features/Emoji/UI/EmojiGridView.swift:339`), the rates-refresh `symbolEffect` (`Features/Calculator/UI/CalculatorCardView.swift:94`), and a few editor `.animation` calls. Selection, hover and preview swaps are instant.
- **Menus.** Every screen uses `PopoverMenu` for actions. No `.contextMenu` or `NSAlert` appears in this surface.

## 2. Weaknesses against a Raycast-grade look

- **The Information block has two looks.**
  - `.callout` with `sm` rows: Clipboard (`ClipboardView.swift:400-401`), ExtensionStore (`Features/ExtensionStore/UI/ExtensionStorePreview.swift:167-168`), DictationHistory (`Features/DictationHistory/UI/DictationHistoryPreview.swift:124-125`).
  - `keyCap` (caption) with `xs` rows: FileSearch (`Features/FileSearch/UI/FileSearchPreview.swift:104-105`), Snippets (`Features/Snippets/UI/SnippetsListView.swift:174-175`), Quicklinks (`Features/Quicklinks/UI/QuicklinkListView.swift:235-236`), CustomCommands (`Features/CustomCommands/UI/CustomCommandPreview.swift:79-80`).
  - All use the system `Divider()` rather than `Theme.Colors.separator`. Icon size is a literal 20 in `ClipboardView.swift:396` and `menuIcon` in Dictation.
- **Interface Size is bypassed.**
  - Pane gutter is a literal `12` in `ClipboardView.swift:304`, `SnippetsListView.swift:114` and `QuicklinkListView.swift:158`; the other panes use `metrics.spacing.xl`.
  - About 35 raw text styles do not scale: `.callout`, `.caption`, `.title3.weight(.semibold)`, `.system(.subheadline, design: .monospaced)`, `.largeTitle`. `ExtensionStorePreview.swift` alone has 13.
  - `EmptyResults.swift:9,18` hard-codes spacing 8 and width 360 and reads no metrics.
  - `QuicklinkListView.swift:122` uses `.font(.system(size: 10))`; the 48 and 64 icon sides are private constants.
- **Two-line rows diverge.**
  - Quicklinks: `rowTrailing`, tertiary, spacing `xxs` (`QuicklinkListView.swift:108-116`).
  - ExtensionStore and Dictation: `keyCap`, tertiary.
  - Rooms: `rowTrailing`, `.secondary`, spacing 0 (`Features/WindowManagement/UI/RoomsList.swift:91-98`).
  - Row heights therefore differ between screens.
  - The "hidden from root" mark is a 10pt `Image(systemName:)` in Quicklinks and a 20pt `SymbolImage` in CustomCommands (`Features/CustomCommands/UI/CustomCommandListView.swift:67`).
  - Clipboard titles use `menuRow`; every other list uses `rowTitle` (same value today).
- **Leading icons are mixed.** Most rows use the colourful tile. Schedule uses a bare 70% `SymbolImage` (`Features/Calendar/UI/ScheduleView.swift:82-86`), and ExtensionStore browse rows use a bare glyph (`Features/ExtensionStore/UI/ExtensionStoreList.swift:135`). Those lists read flatter.
- **There are three in-pane header styles.** Shared `SectionHeader` is semibold `textSecondary`; `EmojiSectionHeader` is not semibold (`EmojiGridView.swift:208`); the "Information" headers use medium `.secondary`; detail pages use tertiary plus a rule.
- **Preview heroes are weak.** A bare 64pt symbol for quicklinks (`QuicklinkListView.swift:151`), a tertiary `.largeTitle` folder (`FileSearchPreview.swift:47`), raw monospaced text straight on the scrim for clipboard and snippets. Previews have no title row, no type badge and no inset card.
- **Preview scrolling is inconsistent.** Only `CustomCommandPreview.swift:64-65` uses `edgeDissolve` and `thinScrollbar`; the clipboard, snippet, store, dictation and file-info scroll views are plain. This probably gives a hard clip beside a dissolving list, unverified.
- **Empty and loading states are thin.**
  - "Loading emoji…" and "Reading menu…" show a magnifying glass.
  - ExtensionStore builds its own progress view and "Press ⌘R" line (`Features/ExtensionStore/UI/ExtensionStoreScreen.swift:243-254`).
  - Hints are prose ("Press ↵ to…") instead of `KeyCapChip`s, and there are no skeleton rows.
- **Motion is missing.** There is no hover or selection easing on rows, no preview crossfade, and no numeric transition on countdown pills or calculator results.
- **Documented rules are broken in places.**
  - `.help()` is used in the palette, where it never shows: `CalculatorCardView.swift:97`, `ExtensionStoreScreen.swift`, and shared `Features/Launcher/UI/SectionHeader.swift:22`.
  - Raw `Image(systemName:)` appears in 14 UI files against the `SymbolImage` rule.
  - The pane separator is a literal `1` in `Features/Clipboard/UI/ClipboardScreen.swift:159`; the others use `Theme.Size.hairline`.
  - The `clipboardListWidth` token sizes seven unrelated screens.
- **Accessibility is uneven.** Clipboard, Snippets, Quicklinks, CustomCommands and CalcHistory rows have no accessibility traits; newer rows do.
- **Glass.** Flat tertiary text sits where a floating control would fit: the preview's type badge, media controls, the camera footer, empty-state hints.

## 3. Opportunities

| # | Change | Files | Size / risk |
| - | - | - | - |
| 1 | One shared `PreviewInfoSection` (label, value as `Text`, optional icon; one font, one row padding, `separator` hairlines) replacing seven copies | new file in `Palette/`; the seven preview files | M / low |
| 2 | One `PaletteSplitView` (list width, hairline, preview gutter, preview scroll treatment); rename the token to `splitListWidth` | seven `*Screen.swift`, `Theme.swift`, `InterfaceMetrics.swift`, `Tests/interface-size-test` | M / low-medium |
| 3 | `.paletteRow(selected:)` modifier, as `leadCard` does, owning fill and armed hover, plus a shared two-line title/subtitle part; this creates one place to add a 0.12s hover ease or a selection rim | 13 row structs, `LauncherList`, `Uninstall` | M / medium: hover state must stay per-row, and `HoverArming` is pinned by `palette-navigation-test` |
| 4 | Replace raw fonts and literals with `metrics` tokens; add `previewTitle` and `previewHeroIcon` | the files listed in §2 | S / low |
| 5 | `EmptyResults` v2: metrics-scaled, family-hue tile, keycap hints, a spinner variant; migrate the store's custom states | `Palette/EmptyResults.swift`, a few call sites | S-M / low; touches `Localizable.xcstrings` |
| 6 | Preview polish: inset stage card (`cardFill`, `cardStroke`, `Radius.card`, `codeBlock` for text), a large `TileArtwork` tile instead of bare glyphs, a title row | preview files | M / low |
| 7 | Glass only where something floats: a frosted capsule with type and size over the preview stage, glass media controls, a glass shutter and mirror pill over the camera feed | `Features/Clipboard/UI/FilePreviewStage.swift`, FileSearch media player, `Camera/UI/CameraView.swift` | M / medium: needs screenshots over a light desktop |
| 8 | Motion: preview crossfade keyed on selection id, `.contentTransition(.numericText())` on countdown and calculator values, symbol effects on pin and install | previews, `Features/Calendar/UI/MeetingRowParts.swift`, `CalculatorCardView.swift` | S-M / medium: held-arrow repeat must not queue animations; the QuickLook surface is reused on purpose (`FileSearchPreview.swift:27`) |
| 9 | Rule fixes: `.help` → `.tooltip`, `SymbolImage`, hairline literals, row accessibility parity, emoji header weight | scattered | S / low |

## 4. Constraints for an implementer

- **Glass is for floating controls only.** The main surface, rows and panes are never glass (`docs/ui.md:26-32,71`). The panel is already glass under a scrim, so glass rows or panes would stack glass on glass. "More glass" on these screens means floating chips and controls, not row backgrounds.
- **Dark values are frozen.** New colours go through `ramp` or `adaptive`; no bare `Color.white.opacity`.
- **`EdgeDissolve.swift` and `ThinScrollbar.swift` are off-limits.** Do not use the native scroll edge effect or put dividers between list and bars; the list-to-preview hairline is the one allowed rule.
- **Extensions stay isolated.** Shared primitives go in `Palette/` or `DesignSystem/` and must not be adopted by, or lifted from, `Features/Extensions/`. `ExtensionMetadataView` is a reference only; duplication there is intended.
- **Read `@Environment(\.metrics)`** on every scaled surface. A new token needs a `Theme` literal, an `InterfaceMetrics` accessor and the `interface-size-test` pin.
- **Motion needs no per-site setting check.** It flows through `motionScope()`.
- **Row and scroll invariants.** Hover state lives on the row. The `scrollFollowsSelection` id must be the `ForEach` identity. Hover is armed by pointer movement.
- **Palette conventions.** Labels use `tooltip`, glyphs use `SymbolImage`, menus use `PopoverMenu`, corners are continuous.
- **A restyle changes no behaviour.** New strings need eight languages and `Scripts/sync-strings.sh`.
- **Files under `Features/*/Model/` import no AppKit or SwiftUI.**

**Already excellent, do not break:** the shared scroll, selection and hover machinery across all lists; the emoji cell's halo selection (`EmojiGridView.swift:309-352`); the calculator and meeting lead cards; the fixed 26pt icon column; the reserved countdown-pill slot (`MeetingRowParts.swift:27-31`); near-complete token discipline (about 17 raw numerics across 15 features); `PopoverMenu` action menus on every screen.

---

# Appendix: research

## Research: raycast

# Raycast visual design research (as of 2026-11)

**Honest summary first:** public sources give almost no numeric design specs. There are no official radii, blur values, row heights or font sizes, and I found no designer teardown. What can be sourced is the direction and a few shipped facts. Everything numeric below is labelled INFERRED and must be checked by eye against a running Raycast. I did not look at screenshots.

## SOURCED facts

1. **Raycast v2 is the redesign for macOS Tahoe.** It requires macOS Tahoe and Apple Silicon. The page says the look and feel were "updated to feel right at home on macOS Tahoe". The blog says every pixel is new and Settings was reorganized and made "more consistent". https://www.raycast.com/new and https://www.raycast.com/blog/the-new-raycast
2. **Liquid Glass is used sparingly.** The blog says it is used "in tasteful ways to enhance the functional nature of a launcher". The material is for function: controls, sidebars and toolbars. It is not for decoration everywhere. https://www.raycast.com/blog/the-new-raycast
3. **Tahoe-ready release v1.103.0 (2025-09-15).** It added Liquid Glass controls in AI Chat, plus new sidebars and toolbars. AI Chat can go full-screen again, and the floating window follows the current Space. https://www.raycast.com/changelog/1-103-0
4. **Architecture.** The host is Swift and AppKit with a WKWebView frontend. Settings is a separate native window, not a modal. Popovers and tooltips are native windows, so they can extend past the window edges. The window is hidden with alpha 0 at launch so the web view can pre-render. https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast
5. **Apple's glass API.** Glass appearance is customised through `cornerRadius` and `tintColor` on `NSGlassEffectView`. https://developer.apple.com/videos/play/wwdc2025/310/
6. **macOS changelog entries on design details.** https://www.raycast.com/changelog/macos/2
   - "Golden Gate" v0.65 (2026-06-18): fixed the corner radius of most windows. Window radii are a tuned, deliberate value.
   - v0.66: new **Interface Size** setting (Default, Large, Larger). It scales all windows, and AI and Notes zoom follow it. Traffic-light alignment was fixed for the larger sizes in v0.67.
   - v0.68 and v0.69: the AI Chat sidebar overlays the content, and content showed through it when the window was blurred. This confirms a translucent overlay sidebar that needs an opaque or glass fallback when the window is inactive.
   - v0.69: improved the design of the "ghost dropdown button" in Settings selects. Selects look like borderless text with a chevron until hovered.
   - v0.69: consecutive AI tool calls collapse into a group.
   - v0.70: simplified the AI Chat composer, confirmation prompt and question layouts. Markdown links turned blue.
   - v0.65: removed flashes of incorrectly parsed content during AI streaming. Streaming text should not reflow.
   - v2.2: added tooltips on list and grid item icons and accessories. Alert icons and Quicklink favicons in compact mode were also fixed.
   - HUD: v0.67 showed the Bluetooth on/off state in the HUD and fixed it appearing on the wrong Space. The HUD is a transient floating pill that follows the active Space.
   - "Improved liquid glass controls when the window is blurred": glass controls have a distinct inactive state.
   - v2.0: improved scrolling performance across the app.
7. **Shared composer.** Quick AI and AI Chat now use one composer, so moving from a quick question to a chat feels continuous. Root search now shows files, folders and contacts alongside commands. Hotkeys and aliases can be assigned inline from root search. The hotkey recorder supports single-tap modifiers such as `fn` and separate left and right modifiers. Tags exist for Snippets, Quicklinks and AI Commands. https://www.raycast.com/blog/the-new-raycast and https://www.raycast.com/new
8. **Dated background (2020).** The original redesign was "less screen real estate" plus "beautiful vibrancy". https://www.raycast.com/changelog/0-22-6

## INFERRED (not sourced; confirm against the live app)

- **Material layering.** Use real glass only for the outer window background, sidebars, toolbars, floating bars and the footer or action bar. Content rows and cards on top should be flat, low-opacity white fills, not nested glass. This follows from "sparing" use in the sourced blog.
- **Dark baseline.** Use a near-black tinted blur, with white overlays of about 4 to 8% for hover and about 8 to 12% for selected rows. A 1px inner highlight (white at about 8 to 12%) and a hairline outer border are typical of Raycast.
- **Corner radii.** Main window about 20 to 26pt, concentric with the Tahoe window radius. Rows about 8 to 10pt, popovers and action panel about 12 to 14pt, icon tiles about 6pt.
- **Row height.** List rows about 40 to 44pt, with the selected row filled and no accent bar.
- **Typography.** SF Pro: 13pt for row titles, 12pt secondary, and 11pt for section headers in medium weight, low-opacity and not uppercase.
- **Icon tiles.** Rounded squares with solid or gradient colour fills and a white glyph, plus a 1px inner stroke.
- **Key caps.** Small rounded rects with a subtle fill and border, 11pt medium text, and a slight bottom shadow.
- **Settings.** The structure is a top tab bar (icons with labels), then a list on the left, then a detail pane or table on the right. Controls are right-aligned with ghost selects. The "ghost dropdown" and "reorganized" claims are sourced, but the exact layout is from my memory of earlier Raycast versions and is unverified for v2.
- **Motion.** Short spring or ease-out transitions of about 150 to 250ms. Selection moves without long animations. Streaming content must not jump.

## Takeaways for Redcast

- Use glass only on chrome (window backdrop, sidebars, toolbars, bottom bars), and flat translucent fills for content.
- Provide a blurred or inactive state for glass controls, and an opaque fallback for overlay sidebars.
- Make selects ghost-style until hovered, make settings a separate native window, and keep popovers and tooltips as native windows.
- Support an Interface Size scale and keep the traffic lights aligned at each size.
- Run a visual side-by-side with installed Raycast v2 (screenshots) to get real numbers, because published ones do not exist.

**Not found despite searching:** designer X posts, a Mobbin teardown, and any official numeric spec.

## Research: liquid-glass

# Liquid Glass, macOS 26 and 27: research for a SwiftUI + AppKit app

Verification: items marked [V] were read on an Apple page this session. [K] is background knowledge that I did not re-verify. [?] means I could not verify it.

Only 5 fetches succeeded. Apple's glassEffect doc page returned only its title, so the SwiftUI signatures below are [K].

## SwiftUI (macOS 26+) [K]
- `func glassEffect<S: Shape>(_ glass: Glass = .regular, in shape: S = DefaultGlassEffectShape()) -> some View`. The default shape is a capsule.
- `Glass` has `.regular`, `.clear` and `.identity`. `.identity` turns the effect off, which is handy for conditional use.
- `Glass` also has `.tint(Color?)` and `.interactive(Bool = true)`. They chain, as in `.regular.tint(.blue).interactive()`.
- `GlassEffectContainer(spacing: CGFloat?) { ... }` groups glass views. They share one sampling region, and shapes within `spacing` of each other blend or morph.
- `glassEffectID(_:in: Namespace.ID)` morphs glass between states. `glassEffectUnion(id:namespace:)` fuses several views into one shape. `glassEffectTransition(.matchedGeometry / .materialize / .identity)` controls insertion and removal.
- `.buttonStyle(.glass)` and `.buttonStyle(.glassProminent)`.
- `backgroundExtensionEffect()` mirrors and blurs content under sidebars and inspectors.
- `scrollEdgeEffectStyle(.soft / .hard, for: .top ...)` styles the scroll-edge blur. `scrollEdgeEffectHidden` hides it.
- `ToolbarSpacer(.fixed / .flexible)` splits toolbar glass groups. `sharedBackgroundVisibility(.hidden)` removes a toolbar item's glass.
- `ConcentricRectangle` plus `containerShape` and `.rect(corners: .concentric)` make corner radii follow the container.
- Reading `glassEffect` through a container: glass cannot sample other glass, so put neighbouring glass in one `GlassEffectContainer`.

## AppKit (macOS 26+)
- [V] `NSGlassEffectView` is an NSView subclass. Its properties are `contentView: NSView?`, `cornerRadius: CGFloat`, `effectIsInteractive: Bool`, `style: NSGlassEffectView.Style` and `tintColor: NSColor?`. Source: https://developer.apple.com/documentation/appkit/nsglasseffectview.md
- [V] `NSGlassEffectContainerView` merges descendant glass views that sit within a proximity of each other (search snippet of its doc). A `spacing` property controls the merge distance [K]. Source: https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview.md
- [K] `NSBackgroundExtensionView` is the AppKit counterpart of `backgroundExtensionEffect`. It has `contentView` and `automaticallyPlacesContentView`. [?] I could not fetch its doc.
- [K] Use `contentView` for anything the glass should hold. Adding subviews directly to the glass view bypasses its vibrancy and layout.

## macOS 27 (WWDC26)
- [V] Apps built with Xcode 27 get the updated Liquid Glass look on the 2027 releases with no code changes. Apple's session says "2027 releases", not "macOS 27" explicitly.
- [V] Liquid Glass follows a new user-facing Liquid Glass slider that adjusts its tint, so tint is now partly the user's choice.
- [V] Custom glass can be marked interactive on macOS, optimised for the pointer. The session transcript does not name the API, so it is probably the existing `.interactive()`. [?]
- [V] On iPadOS and macOS, icons and text dim when the window is inactive. Use `@Environment(\.appearsActive)` to match it in custom views.
- [V] The new SwiftUI APIs are `ToolbarOverflowMenu`, `.visibilityPriority(.high)` and `.toolbarMinimizeBehavior(.onScrollDown, for:)`. The last one is documented for `.navigationBar`, so it may be iOS-only. Menu bar icons are minimal by default, and `.labelStyle(.titleAndIcon)` restores them. Source: https://developer.apple.com/videos/play/wwdc2026/269/
- Secondary, pre-WWDC and press reporting [?]: less default transparency, more diffusion of busy content behind glass for readability, and adjusted sidebar corners on macOS. Sources: https://www.mactrast.com/2026/05/liquid-glass-wont-go-away-in-macos-27-although-it-will-receive-a-facelift-plus-a-new-safari-feature-will-debut/, https://en.wikipedia.org/wiki/Liquid_Glass, https://www.cultofmac.com/news/macos-27-new-features-beyond-siri-ai
- [?] I found no new glass modifier signatures in macOS 27. The session did not mention scroll edge or `glassEffect` changes. Check the Xcode 27 SDK headers for the real diff.

## Non-activating borderless NSPanel and arbitrary desktop content
- [V] Forum thread 818901: on macOS 26 only the key window shows the active glass look. A non-key panel always renders the inactive, frosted look. It still does so with `.nonactivatingPanel`, `canBecomeKeyWindow = false`, `orderFrontRegardless()` and `addChildWindow`. The only reply is from Apple DTS asking for a sample project, so there is no confirmed cause or fix. That thread used NSVisualEffectView with the glass material. https://developer.apple.com/forums/thread/818901
- Untested ideas, mine and not from Apple: set `NSVisualEffectView.state = .active`, or put every glass region in one window. This matters for a launcher palette that never becomes key. Redcast should test early whether its panel renders active glass.
- [V] Forum thread 810314: a borderless transparent window at Dock level with `canJoinAllSpaces`. On 26.0 and 26.1 the glass updated correctly. On 26.2 the `NSGlassEffectView` background looked cached and did not update when other windows moved underneath. Setting `movable` and `movableByWindowBackground` made it update when the window itself moved, but not for windows beneath. There was no reply and no fix. https://developer.apple.com/forums/thread/810314
- Untested workarounds: fall back to NSVisualEffectView, toggle `isHidden` to force a redraw, or file a Feedback report.
- Borderless plus non-activating panels has known quirks that are not glass-specific. The mouse cursor does not change over text fields (repro: https://www.github.com/PitNikola/NonActivatingPanelIssue). A fully non-activating setup relies on a private API and swizzling to appear over full-screen apps [from a search snippet, not read].
- Another thread to read: SwiftUI buttons behind NSToolbarView are not clickable on macOS 26 beta (https://developer.apple.com/forums/thread/788928). I did not read it.

## Interaction with NSVisualEffectView
- [K] Both are system-composited blur materials. Do not stack them. Replace NSVisualEffectView with NSGlassEffectView where you want glass. Keep NSVisualEffectView for sidebar, window-background and HUD materials.
- [V, from the thread above] A glass-style NSVisualEffectView panel shows the same non-key problem.

## Accessibility settings [K]
- Reduce Transparency makes glass frosted and more opaque. Increase Contrast adds borders and makes it more opaque. Reduce Motion tones down the interactive and morph effects. The system handles all of these automatically for the standard APIs.
- Do not hard-code glass-dependent colours or shadows. Check text contrast in the clear and tinted modes the user can pick. macOS 26.1 added a Clear vs Tinted toggle in Settings.
- Per the WWDC26 session [V], macOS 27 adds the tint slider, so verify legibility across its range.

## Performance and pitfalls
- [K] Each glass layer samples and blurs what is behind it, in real time. Use a single `GlassEffectContainer` per cluster. Avoid dozens of separate glass rows in a long list, and apply glass to the container, not per item.
- [K] Avoid glass on glass. Do not animate large glass shapes continuously. Prefer `.clear` only over rich media, with a dimming layer under it.
- [K] Developers reported that `.glassEffect` inside lists and scroll views causes dropped frames. [?] I found no source for this in this session.
- [K] Reported issues: interactive glass flicker, tint bleeding, and the container merging shapes you did not want merged. [?] No source found. Reduce `spacing` to stop unwanted merging.

## HIG rules [K, from Apple's Liquid Glass guidance; not re-fetched]
- Glass belongs to the navigation and control layer that floats above content, such as toolbars, sidebars, tab bars, controls and popovers. Content itself is not glass.
- Never stack glass on glass. A standard container needs only one glass layer.
- Use concentric corners so controls follow their container's radius. Use `ConcentricRectangle`, and keep corner radii consistent with window corners.
- Tint only for meaning, such as a primary action. Do not tint everything.
- Legibility comes first. Prefer `.regular` for text-heavy glass, because `.clear` needs a dim layer behind it.
- Recompile with the new SDK and drop custom backgrounds on bars, so system bars get the new look.

## Not covered or unverified
- Actual macOS 27 signatures, behaviour in non-activating panels on macOS 27, and measured glass costs. Apple's glassEffect doc page returned empty text, so check it directly: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
- Other source: https://dev.to/arshtechpro/understanding-glasseffectcontainer-in-ios-26-2n8p (search result only, not read).

## Research: top-apps

# Premium desktop UI craft: research digest (2026-11)

Caveat: official specs from Raycast, Things, Craft, Arc, Alfred, Sol, Loop and CleanShot were not found. Raycast numbers below come from a third-party reverse-engineering of its website, not its macOS app. Linear and Apple facts are from first-party posts. Spring numbers are third-party and disagree with each other. Treat everything marked "heuristic" as my synthesis, to be tuned by eye.

## 1. Layered depth (Raycast-derived, dark)
Source: [Raycast design extract](https://design.hagicode.com/designs/raycast/DESIGN.md). The same source lists a near-black background `#07080a` and a card surface `#101111`.
- **Hairline border.** Card containment is `1px rgba(255,255,255,0.06)`. Secondary buttons use 0.10 and inputs 0.08. Use white-alpha, never a gray hex, so the border adapts to whatever material is behind it.
- **Inset top highlight.** Buttons use `rgba(255,255,255,0.05) 0 1px 0 inset`. The pill variant uses 0.10. Add a faint bottom inset `rgba(0,0,0,0.2) 0 -1px 0 inset` for a pressed-plate look.
- **Ring plus inset ring.** The card ring is `#1b1c1e 0 0 0 1px` with `#07080a 0 0 0 1px inset`. This gives a two-tone edge and avoids heavy shadows.
- **Shadows.** The source's level 1 is `rgba(0,0,0,.28) 0 1.2px 2.4px`. Its floating level adds a `0 0 0 2px rgba(0,0,0,.5)` outer ring plus a soft light glow. For a floating panel, my heuristic is a 3-layer stack: contact `0 1px 2px black@.30`, mid `0 8px 24px black@.25`, ambient `0 24px 64px black@.35`.
- **Tinted glows for status.** Blue `rgba(0,153,255,.15)` and red `rgba(255,99,99,.15)`. A warm ambient glow, `rgba(215,201,175,.05) 0 0 20px 5px`, is used for features.
- **Focus.** Use a soft ring in the accent color at 15% alpha, not a hard outline.

## 2. Concentric radii (Apple)
Source: [WWDC25 session 356](https://developer.apple.com/videos/play/wwdc2025/356/).
- Inner radius = parent radius minus padding. A capsule's radius is half its height.
- Apple recommends a concentric shape with a fallback radius for components that appear both inside and outside a container.
- Raycast web radii run from 4–5 (key caps) to 6 (buttons and badges), 8 (inputs), 12 (cards), 16 (large) and 20 (hero). Panel 16 → row inset 6 → row radius 10 is an example of the rule. Use `ConcentricRectangle`-style math rather than hardcoding.

## 3. Typography
- Raycast uses Inter, with OpenType `calt, kern, liga, ss03`. It sets body text in weights 400–500, with 600 reserved for buttons and small labels. Letter-spacing is a slight positive 0.1–0.3px at 12–16px, and 0 at display sizes. Source: [Raycast extract](https://design.hagicode.com/designs/raycast/DESIGN.md).
- Linear uses Inter Display for headings and regular Inter for everything else. Source: [Linear redesign](https://linear.app/now/how-we-redesigned-the-linear-ui).
- Raycast's caption is 14/500 and its small text 12/600. Code is monospace at 12–14.
- Heuristics for native macOS (SF Pro): use a short scale of 11 / 12 / 13 / 15 / 20. Rows are 13/500 for the title and 12/400 secondary for the subtitle. Section headers are 11/600, in a quiet secondary color, with no uppercase tracking tricks needed.
- Use `.monospacedDigit()` for numbers and times so values do not jitter.
- Metadata is quieter than titles. Raycast's text ladder runs `#fff`, `#cecece`, `#9c9c9d`, `#6a6b6c`. Four levels is enough.

## 4. Spacing rhythm
- Raycast's base unit is 8, with scale 1, 2, 3, 4, 8, 10, 12, 16, 20, 24, 32, 40. Gaps between components are 8–16 and card padding is 16–32. Source: [Raycast extract](https://design.hagicode.com/designs/raycast/DESIGN.md).
- Linear's stated goals were reducing visual noise, keeping vertical and horizontal alignment of icons, labels and buttons, and a neutral, timeless look. It set density and alignment by eye, with no published numbers. Source: [Linear redesign](https://linear.app/now/how-we-redesigned-the-linear-ui).
- Heuristic: use 4pt for inside a component and 8pt between components. Row height is 36–40pt for a two-line launcher row and 28–32pt for a compact row.

## 5. Color, accent and light mode
- Linear moved theme generation from HSL to LCH, which is perceptually uniform. Each theme is now 3 inputs (base, accent, contrast) instead of 98 variables. It also cut blue from the chrome for a more neutral feel. Surfaces are layered by elevation: background, foreground, panels, dialogs, modals. Text and icons go darker in light mode and lighter in dark mode. Source: [Linear redesign](https://linear.app/now/how-we-redesigned-the-linear-ui).
- Raycast keeps the accent restrained. Red `#FF6363`, blue `#55b3ff`, green `#5fc992` and yellow `#ffbc33` appear mostly as 15% tints behind badges, not as large fills.
- Heuristic for light-mode parity: dark uses white-alpha ramps and light uses black-alpha ramps. Light mode needs a real shadow, since white-on-white highlights vanish. Use a 0.5px darker hairline and keep the top highlight at a brighter white than the fill.
- Per the project's own AGENTS.md, only change a light branch freely. Never touch the dark literals.

## 6. Icon tiles, selection vs hover, key hints
Source for these three: Raycast keycap stack from [Raycast extract](https://design.hagicode.com/designs/raycast/DESIGN.md); the rest is heuristic.
- **Icon tile.** A rounded square at about 22–28pt with radius about 0.25 of its side. Use a 1px white@0.10 hairline and a subtle top-to-bottom gradient of ±6% brightness. Put an inset top highlight on it. The glyph is white at 0.9, SF Symbol weight medium.
- **Selection vs hover.** Selection is a fill, `white@0.08–0.10` in dark, with a radius concentric to the panel. Hover is `white@0.04` with no border. Selection should never animate in with a slow fade. Hover can ease in at 80–100ms.
- **Keyboard hints.** Keycaps run 4–6 radius with a gradient `#121212` to `#0d0d0d`, a 1px ring and a lit top edge. They go in the row's trailing edge and in a footer bar. Superhuman shows each command's shortcut so users learn it ([Superhuman guide](https://blakecrosley.com/guides/design/superhuman)). Show the primary action hint only on the selected row, to cut noise.

## 7. Empty, loading and error states
Mostly heuristic; no first-party source found.
- **Empty.** An icon at 32pt in secondary color, a one-line title at 13/600, a one-line hint, and a single primary action.
- **Loading.** Hold the current results and show a thin progress indicator. Skeleton rows must match the final row height so nothing shifts.
- **Error.** Use a red-tint@0.15 badge and a retry. Present it inline and avoid blocking dialogs.

## 8. Motion and springs
Third-party numbers (see [Create with Swift](https://www.createwithswift.com/understanding-spring-animations-in-swiftui/) and [animation reference](https://tessl.io/registry/dpearson2699/swift-ios-skills/3.6.1/files/skills/swiftui-animation/references/animation-advanced.md)):
- `.snappy` is about 0.25–0.4s and maps roughly to `spring(response: 0.3, dampingFraction: 0.85)`.
- `.smooth` is about 0.35–0.5s and maps roughly to `spring(response: 0.5, dampingFraction: 1.0)`.
- `.bouncy` is about `spring(duration: 0.5, bounce: 0.3)`.
- A damping fraction near 0.9 settles softly. Values of 0.4–0.5 look clearly bouncy.

Heuristic usage:
- Panel open: scale 0.97 to 1 plus opacity, `.snappy`, about 180–220ms.
- Panel close: faster than open, about 120ms, with no spring.
- Press feedback: 0.98 scale at about 80ms.
- List selection: no animation at all, instant.
- Reduce Motion: replace springs with a plain opacity fade at 100ms.

## 9. Scrolling polish
Heuristic.
- Fade rows at the edges rather than a hard clip. The project already has `EdgeDissolve` and `ThinScrollbar`, which are off-limits.
- Keep section headers pinned.
- When arrow-key selection moves, scroll only as far as needed to keep the row in view, without recentering.

## 10. Speed and perceived latency
- Responses under 100ms read as immediate. Users sense lag at roughly 20–80ms. Source: [Ink & Switch](https://inkandswitch.com/slow-software/).
- A Superhuman guide claims a 50–60ms internal target. It is a secondary source and I could not verify it. Source: [Superhuman guide](https://blakecrosley.com/guides/design/superhuman).
- Update optimistically, move focus on immediately, and sync in the background. Linear pairs this with rollback on failure and aggressive caching. Source: [Linear guide](https://blakecrosley.com/guides/design/linear).
- Artificial delay makes an interface feel slower. A 300ms response shown at 800ms feels worse than one shown at once. Source: [design timing guide](https://designhubs.pages.dev/interaction/i13-interaction-timing).
- Source for the palette point: [command palette essay](https://letanure-new.pages.dev/writing/command-palettes-are-a-primitive). Keystroke to rendered results should be under 100ms.
- I found nothing on layout shift. My heuristic:
  - Fix row heights and the panel height ceiling.
  - Reserve space for icons so async icon loads do not reflow.
  - Keep the first result selected by default.
  - Keep the previous list visible until the new one is ready.

## 11. Accessibility and materials on macOS 26
Sources: [Tidbits](https://tidbits.com/2025/10/09/how-to-turn-liquid-glass-into-a-solid-interface/) and [Infinum](https://infinum.com/?p=19266836).
- Reduce Transparency makes glass frostier and more opaque. Increase Contrast turns Reduce Transparency on automatically. Reduce Motion lowers animation intensity.
- Observe `accessibilityDisplayShouldReduceTransparency`, `...IncreaseContrast` and `...ReduceMotion`. In those modes swap the glass for a solid elevated fill with a stronger 1px border.
- Legibility rule: text on glass needs a tinted scrim behind it. Test on light wallpapers.
- Unconfirmed: a MacRumors thread says Apple is tuning Liquid Glass for macOS 27, with uniform toolbars and matching window corner radii. Check it before relying on it.

## Not covered
Things 3, Craft, Arc/Dia, Notion Calendar, Spotlight, Alfred, Sol, Loop and CleanShot returned no usable first-party details.
