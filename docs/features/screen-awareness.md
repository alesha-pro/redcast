# Screen Awareness

**Ask About Screen** reads the window in front of you and opens Quick AI with it attached, ready for
a question: the app and window title, the page's URL in a browser, the selected text, the field the
caret is in, the window's readable text and, when allowed, a screenshot of that window. It is the
fork's take on Raycast's Screen Awareness; upstream lists screen reading under
[not planned](../not-planned.md), so this feature lives only here, kept to `Features/ScreenAwareness/`
plus the few lines that wire it in.

## Invariants

- **Off out of the box, and off means the command does nothing.** `AppSettings.screenAwarenessEnabled`
  is the flag, `ScreenAwarenessCoordinator` the only reader. With it or `aiEnabled` off the launcher row
  leaves through `AppIndex.setCommandsVisible`, and a bound shortcut stays registered but returns at
  once. Both it and `screenAwarenessScreenshot` grant a capability, so neither travels in a backup nor
  has a settings-file key.
- **Enabling is consent.** The toggle confirms through `DialogController` first, then asks for
  Accessibility, as Quick Actions do. Turning the screenshot on is what asks for Screen Recording;
  without that grant a capture simply carries no picture and one HUD line says why.
- **Only on a gesture, and never Tinycast itself.** Nothing is read until the command runs. With the
  palette open the target is the app behind it (`PaletteCoordinator.targetApp`); with it closed, the
  frontmost app. Tinycast's own bundle is refused with a HUD rather than captured.
- **Passwords are not context.** A secure text field is skipped by role or subrole everywhere the walk
  looks, and the focused field is dropped entirely while Secure Event Input is on.
- **The window's text gives way first.** `ScreenContextFormatter` keeps the header, the selection and
  the focused field, then fills what remains of `AIAttachmentBudget.maxInlinedTextBytes` with window
  text. A cut always says so — a capture that silently stops is a page the model believes it read whole.
- **What was on screen is material, not a request.** The text attachment opens by saying so. A window
  title is forced onto one line, so it cannot forge a header row, and the attachment is named after the
  app alone.
- **A picture the route cannot see stays behind.** `QuickAICoordinator.showStaging` checks
  `AIModelCapabilities.images`; on a text-only route only the text is staged and a HUD says so, rather
  than staging an image the send would refuse.

## Layout

| File | Holds |
| --- | --- |
| `Model/ScreenContext.swift` | The capture's parts; `ScreenTextPolicy`: readable roles, secure roles, walk limits, line normalizing |
| `Model/ScreenContextFormatter.swift` | The capture as the Markdown attachment, its budget and its name |
| `Service/ScreenContextReader.swift` | The Accessibility walk, off-main: focused window, title, frame, web area URL, focused field |
| `Service/WindowScreenshotter.swift` | Finds the window by pid and frame, captures it with ScreenCaptureKit; `ScreenRecordingAccess` |
| `UI/ScreenAwarenessCoordinator.swift` | The one funnel: target, permission, capture, staging |
| `Settings/ScreenAwarenessSettingsSection.swift` | The AI pane's section |

## Reading the window

The selection is read first, on the main actor, through `AccessibilityText` — the same two tiers Quick
Actions use, minus the borrowed ⌘C: a capture never synthesizes a keystroke into somebody's app.
Everything else is `ScreenContextReader.read`, run detached:

- `AXManualAccessibility` is set on the application first, so Chrome and Electron build a tree.
- The focused window (`AXFocusedWindow`, else `AXMainWindow`) gives the title and the frame.
- A depth-first walk, in tree order, collects the value, title or description of every element whose
  role is in `ScreenTextPolicy.textRoles`. One `AXUIElementCopyMultipleAttributeValues` per node keeps
  it to a single round trip, and `maxNodes`, `maxDepth` and `maxDuration` stop an enormous or wedged
  tree. A single value is capped at 4,000 characters, since an editor can hold a whole file in one.
- The first `AXWebArea` met answers `AXURL`, which is how a browser tab's address arrives without a
  browser extension.

## The screenshot

`WindowScreenshotter` matches the window in `CGWindowListCopyWindowInfo` by pid, layer 0 and the frame
Accessibility reported (within four points), falling back to the app's frontmost normal window. That
list needs no Screen Recording grant because window names are never read. The capture itself is
`SCScreenshotManager.captureImage` over `SCContentFilter(desktopIndependentWindow:)` at the display's
pixel scale, without cursor or shadow. The PNG then goes through `ChatAttachmentReader.image`, so it is
bounded to 1568px like any pasted picture.

## Manual sweep

- Turn Screen Awareness on in Settings → AI: the dialog asks first, then Accessibility is requested.
  Bind a shortcut to Ask About Screen under the AI pane's commands.
- In Safari, select a sentence and press the shortcut: Quick AI opens with `Screen — Safari.md`
  holding the URL, the selection and the page's text, and the question goes out with it.
- In Chrome and in an Electron app (Slack, VS Code): the window text is there, not empty.
- In Mail with the caret in a reply: the focused field carries the draft.
- In a password field, press it: the focused field is absent from the capture.
- Turn on Include a screenshot: macOS asks for Screen Recording once. Granted, the capture carries the
  window's picture; refused, it carries text and one HUD line points to System Settings.
- Pick a text-only model in Quick AI and capture: only the text is staged, and a HUD says why.
- Run Ask About Screen from the launcher (⌘Space → "Ask About Screen"): the app behind the palette is
  what gets captured, not Tinycast.
- With Tinycast's Settings in front, press the shortcut: refused with a HUD.
- Turn the feature off: the launcher row disappears and the shortcut does nothing.
- Harness: `screen-awareness-test` (section order, budget and cut markers, forged titles, secure roles,
  line normalizing).
