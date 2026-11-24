# gifshot

A tiny macOS menu bar app that records a region of the screen straight to an animated GIF.
See [BRIEF.md](BRIEF.md) for scope and design decisions.

| Shortcut | Action |
|---|---|
| `⌃⌥⌘3` | Record the full screen under the cursor |
| `⌃⌥⌘4` | Drag to select a region, release to start recording (Esc cancels) |
| Either shortcut, or click the menu bar icon | Stop recording |

Recordings stop on their own after 60 seconds. GIFs are saved to `~/Desktop/gifshot-<timestamp>.gif` and copied to the clipboard.

## Requirements

macOS 27 and Xcode (for the Swift toolchain).

## First-time setup: signing identity

macOS ties the Screen Recording permission to the app's code signature. An ad-hoc signature changes on every build, so macOS would forget the permission after each rebuild. gifshot is signed with a stable local identity named `gifshot Local` instead:

1. Open **Keychain Access**.
2. Choose **Keychain Access > Certificate Assistant > Create a Certificate…**
3. Name: `gifshot Local`. Identity Type: **Self-Signed Root**. Certificate Type: **Code Signing**.
4. Click **Create**. You can leave it in your login keychain.

To use a different identity, such as an Apple Development certificate, pass its name or SHA-1 hash:

```bash
make run SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

`security find-identity -p codesigning` lists the identities you have.

## Build and run

```bash
make run
```

| Target | What it does |
|---|---|
| `make` | Build (release) and assemble and sign `build/gifshot.app` |
| `make run` | The above, then quit any running copy and launch it |
| `make clean` | Remove `.build/` and `build/` |

The first recording asks for Screen Recording permission. After you allow it in System Settings, quit gifshot and run it again. The first save may also ask for access to the Desktop folder.

## License

MIT. See [LICENSE](LICENSE).
