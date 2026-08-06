# KeyDisplay

A tiny macOS keystroke visualizer for teaching, screencasts, and live demos. Your keystrokes appear in a corner of the screen in large text, then fade away.

Built as a single Swift file — no Xcode project, no dependencies.

## Features

- **Corner overlay** — keystrokes show in a dark rounded chip with large monospaced text
- **Modifier symbols** — shortcuts render as `⌃C`, `⌘⇧P`, `⇥`, `↩`, `⎋`, arrows, F-keys
- **Typing bursts** — a pause in typing (1 s) starts a new line; older lines fade out gradually
- **Line wrapping** — long bursts wrap instead of being cut off
- **Repeat collapsing** — held keys show as `⌫×12` instead of flooding the screen
- **Multi-monitor** — follows the screen your mouse is on, or pin it to one display
- **Menu-bar controls** (⌨ icon) — pause/resume, corner position, display, text size
- **No dock icon** — runs quietly as a menu-bar app

## Install

Building from source (below) is recommended — it takes seconds and avoids Gatekeeper warnings. A prebuilt app is also available on the [Releases page](https://github.com/yqtian-se/keydisplay/releases); since it isn't notarized, macOS will require **System Settings → Privacy & Security → Open Anyway** on first launch.

```bash
git clone https://github.com/yqtian-se/keydisplay.git
cd keydisplay
./build.sh
open KeyDisplay.app
```

Requires macOS 13+ and the Xcode command-line tools (`xcode-select --install`).

## Permissions

macOS requires **Input Monitoring** permission for any app that captures keystrokes globally:

1. Launch the app — it shows "waiting for Input Monitoring permission…" in the corner.
2. Open **System Settings → Privacy & Security → Input Monitoring**.
3. Click **+**, press **⌘⇧G**, and select the built `KeyDisplay.app`, then enable its toggle.
4. The corner chip flips to "KeyDisplay ✓" within a couple of seconds. If it doesn't, quit and relaunch the app — permission grants only apply to freshly launched processes.

### Keeping the permission across rebuilds

`build.sh` signs with an ad-hoc signature by default, which changes on every build — so macOS drops the permission each time you rebuild. If you plan to hack on the code, create a self-signed code-signing certificate once and the permission will stick:

1. Open **Keychain Access** (hidden on recent macOS — use Spotlight or `open -a "Keychain Access"`; the *Passwords* app is not the same thing).
2. Menu bar: **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name: `KeyDisplay Dev`, Identity Type: *Self-Signed Root*, Certificate Type: **Code Signing**.
4. Rebuild. When prompted that codesign wants to use the key, enter your password and click **Always Allow**.

`build.sh` automatically uses the `KeyDisplay Dev` certificate when it exists.

## Troubleshooting

**Keys don't show while a terminal is open** — Terminal.app's *Secure Keyboard Entry* (Terminal menu) blocks keystroke capture **system-wide** while Terminal is running, even for keys typed in other apps. Uncheck it, or quit Terminal. iTerm2 has the same option under its own menu.

On managed (MDM) machines, IT may force this setting on so it cannot be unchecked — check `/Library/Managed Preferences/<user>/com.apple.Terminal.plist`. In that case use a terminal the policy doesn't cover, e.g. VS Code's integrated terminal or iTerm2.

**Nothing shows at all** — make sure the corner chip said "KeyDisplay ✓". If it still says "waiting for permission", re-check Input Monitoring and relaunch the app.

## Customizing

Everything lives in [main.swift](main.swift) (~300 lines). Obvious knobs: fade delay and durations, `lineBreakAfter` pause, colors in `setupWindow`, the overlay width fraction (0.45), and the key-symbol table at the top. Rebuild with `./build.sh`.

## License

[MIT](LICENSE)
