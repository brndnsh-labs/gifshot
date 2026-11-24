# gifshot

Read `BRIEF.md` first. It is the source of truth for scope, decisions, and acceptance criteria. If a decision there needs to change, update the brief in the same change.

- Swift, AppKit, ScreenCaptureKit, ImageIO. No third-party dependencies.
- Build with `make` targets only; keep the Makefile the single source of truth.
- Target macOS 27; no `#available` branches.
- Bundle ID `zip.brndn.gifshot` is permanent.
