# gifshot: Brief

A tiny native macOS menu bar app that records a region of the screen straight to an animated GIF. Inspired by Shottr: fast, native, stays out of the way. Shottr does great screenshots but has no GIF capture, and the free GIF recorders (Kap, etc.) tend to rot and crash on new macOS releases.

**Guiding principle:** small and maintainable over feature-rich. Fewer than ~1,000 lines of Swift for v1, zero third-party dependencies, only current Apple APIs.

Status: planning complete, ready for implementation.

---

## Decisions

| Area | Decision | Why |
|---|---|---|
| Form factor | Menu bar app (`LSUIElement`, no Dock icon) | Shottr-style; shareable as a real product |
| Platform | macOS 27+ only | No `#available` branches; owner runs only current OS. Dropping to 26 later should be a one-line change. |
| Language | Swift, AppKit (SwiftUI only where it's clearly simpler) | Native, small binary, fast launch |
| Build | SwiftPM + `Makefile` (`swiftc` builds, `make` assembles the `.app` bundle) | Plain-text, diffable, no `.xcodeproj` churn. `Package.swift` can still be opened in Xcode for editing. |
| Capture | ScreenCaptureKit (`SCStream` with a `sourceRect`) | Apple's current API; older capture APIs are why other recorders break |
| Encoding | ImageIO (`CGImageDestination`, GIF), encoded in batches of 10 frames whose blocks are spliced into one file as recording proceeds | Built in, no ffmpeg. ImageIO holds every frame until finalize and then needs ~2x their raw size at once (~7 GB for 60 s of full screen), so one destination per recording isn't viable. Quantization is mediocre; revisit (e.g. gifski) only if it's a real problem. |
| Dependencies | None | Maintainability |
| Distribution | Personal only for v1 | Signed with a local stable identity via `SIGN_IDENTITY`. Notarization would be a future `make release` target, not a rewrite. |
| Name / bundle ID | `gifshot` / `zip.brndn.gifshot` | Bundle ID is permanent: TCC permissions are keyed to it. Don't change it. |

## v1 scope

1. **Global hotkeys**, each a toggle (press again, or click the menu bar icon, to stop):
   - `Cmd+Opt+Ctrl+3`: record the full screen of the display under the cursor. Starts immediately.
   - `Cmd+Opt+Ctrl+4`: region selection overlay. Drag a rectangle, release to start recording.
   - While recording, either hotkey stops. Chosen to mirror macOS's `Cmd+Shift+3/4` screenshot shortcuts without colliding with them (`Ctrl+Cmd+Shift+3/4` is also taken by macOS). `Cmd+Shift+7` was rejected: it's the numbered-list shortcut in many text apps.
2. **Recording indicator:** menu bar icon changes state and shows elapsed time (e.g. `0:12`) while recording; thin border around the captured region (excluded from capture).
3. **Length cap:** recording auto-stops at 60 seconds and saves what was captured, same as a manual stop.
4. **Output:** GIF written to `~/Desktop/gifshot-<timestamp>.gif` and copied to the clipboard (file URL plus GIF data, so it pastes into Slack/Finder/etc.).
5. **Defaults:** 15 fps, loop forever. Max width (downscale only, preserve aspect): 800 px for regions, 1280 px for full screen. Full screen gets the larger cap so text stays readable; full-screen GIFs will still be large, which is inherent to the format.
6. **Menu:** Record Full Screen, Record Region, Open last GIF, Reveal output folder, Quit.

## Out of scope for v1

Editor/trimming, settings window, MP4 export, audio, window capture mode, cloud upload, launch at login (likely v1.1), auto-update.

## Implementation notes

- **Hotkeys:** Carbon `RegisterEventHotKey` (two registrations). Still works, needs no Accessibility permission, no dependency.
- **Full screen:** `SCContentFilter` for the `SCDisplay` containing the mouse location; exclude gifshot's own windows.
- **Region selection:** one borderless, transparent `NSWindow` per screen at `.screenSaver` level; crosshair cursor; Esc cancels. Convert the selection to the display's coordinate space for `SCStreamConfiguration.sourceRect`, accounting for backing scale factor.
- **Frames:** `SCStreamOutput` delivers `CMSampleBuffer`s. Convert to `CGImage` (`SCStreamConfiguration` width/height does the downscale) and encode as frames arrive (don't buffer the whole recording in memory). `GIFWriter` encodes each batch with its own palette, converted to per-frame local color tables. Each batch re-encodes the previous batch's last frame and drops it, so frames stay small transparent diffs across batch boundaries. Use real timestamps for per-frame delay so dropped frames don't speed up playback.
- **Permissions:** Screen Recording via TCC. Handle the not-yet-granted case with a clear message and a button that opens the right System Settings pane.
- **Signing gotcha:** TCC ties the Screen Recording grant to the code signature. Ad-hoc signing (`codesign -s -`) produces a new identity each build, which can make macOS forget the permission on every rebuild. Sign with a stable identity (a local self-signed cert or an Apple Development cert) via a `SIGN_IDENTITY` variable in the Makefile.

## Proposed layout

```
gifshot/
  BRIEF.md
  Package.swift
  Makefile              # build, bundle, sign, run, clean
  Resources/
    Info.plist          # LSUIElement, zip.brndn.gifshot, min OS 27
  Sources/gifshot/
    App.swift           # NSApplication setup, status item, menu
    Hotkey.swift        # Carbon hotkey registration
    RegionPicker.swift  # overlay windows, selection
    Recorder.swift      # SCStream setup and frame delivery
    GIFWriter.swift     # ImageIO incremental GIF encoding
    Output.swift        # file naming, clipboard, reveal
```

## Done when (v1 acceptance)

- [ ] `make run` builds and launches the app from a clean clone on macOS 27
- [ ] Hotkey, drag, record, hotkey: a GIF appears on the Desktop and in the clipboard
- [ ] 10-second recording of an 800 px-wide region stays under ~5 MB and plays at correct speed
- [ ] Recording auto-stops and saves at 60 seconds; elapsed time is visible in the menu bar
- [ ] Esc during selection cancels cleanly; no stray windows
- [ ] Works on a multi-display setup and on Retina and non-Retina screens
- [ ] Rebuilding doesn't re-prompt for Screen Recording permission (stable signing)
- [ ] No third-party dependencies

## Open questions

None. Ready for implementation.

## Environment notes for agents

- First-time setup: create a self-signed code-signing certificate named `gifshot Local` in Keychain Access (Certificate Assistant > Create a Certificate, type Code Signing) and use it as the default `SIGN_IDENTITY`. Document this in a README.

- The owner builds and runs locally on macOS 27 with Xcode's toolchain installed.
- Prefer `make` targets over ad hoc commands; keep the Makefile the single source of truth for building.
