# TriTab

**Three-finger tab control for Mac** ／ [日本語](README.ja.md)

TriTab is a small menu bar app that lets you switch, close, reopen and open browser tabs with trackpad gestures. It's free and open source (MIT).
It uses about 13 MB of memory while running (BetterTouchTool: about 48 MB).

## Install

- **DMG**: download the latest `TriTab-x.y.z.dmg` from [Releases](https://github.com/iKora128/tritab/releases/latest), open it, and drag TriTab to Applications.
- **Homebrew**: `brew install --cask ikora128/tap/tritab`

Requires macOS 13 Ventura or later, on Apple silicon or Intel. TriTab is signed with a Developer ID, notarized by Apple, and keeps itself up to date.

## Getting started

1. **Allow Accessibility access**: System Settings › Privacy & Security › Accessibility. TriTab needs it to send keyboard shortcuts.
2. **Move macOS's three-finger gestures to four fingers**: System Settings › Trackpad › More Gestures. TriTab tells you if anything conflicts.
3. **If you use Three Finger Drag**, set TriTab to four fingers in Settings.

## Tab gestures (on by default)

| Gesture | Action |
|---|---|
| Swipe left with 3 fingers | Next tab (to the right) |
| Swipe right with 3 fingers | Previous tab (to the left) |
| Swipe down with 3 fingers | Close tab |
| Swipe up with 3 fingers | Reopen closed tab |
| Tap with 3 fingers | New tab |
| Click (press down) with 3 fingers | ⌘-click (open the link in a new tab) |
| Click with 4 fingers | Reopen closed tab |
| Pinch with your thumb and 2 fingers | Reload |

- One swipe moves one tab. Slow drifts and re-placed fingers don't trigger anything.
- While three fingers are on the trackpad, TriTab keeps two-finger scrolling from triggering Back / Forward by accident.
- Shortcuts are adjusted per app (for example ⌘⌥↓ in Arc and ⌘⌥→ in VS Code). Other apps get ⌃Tab / ⌘W / ⇧⌘T.
- Close and reopen don't work in terminal apps. Slack, Discord and Mail are left alone.

## Extras (off by default, turn on in Settings)

- **⌘ alone for Eisu / Kana**: left ⌘ switches to Eisu (英数), right ⌘ to Kana (かな), like the popular Karabiner-Elements rule.
- **Four-finger tap to toggle Eisu / Kana**
- **Notch Shelf**: drag a file and nudge it upward, and a shelf slides out of the notch to hold it for later. Hovering over the notch opens it too, and while it's open you can paste files, images or text with ⌘V.
- **Five-finger swipe up to sleep the display**

## Settings

Choose Settings… (⌘,) from the menu bar icon. The settings window runs in its own process and quits when you close it, so the always-running part of TriTab stays small.

## Privacy

- TriTab reads trackpad touches and keyboard and mouse events on your Mac only to recognize gestures and shortcuts. Nothing is recorded or sent anywhere.
- The only network access is the update check. TriTab downloads `https://github.com/iKora128/tritab/releases/latest/download/appcast.xml` once a day if you allow automatic checks (it asks on the second launch), or when you choose Check for Updates…. There is no analytics and no system profiling.
- Your data stays on your Mac: settings in `~/Library/Preferences/io.github.ikora128.TriTab.plist`, Notch Shelf memos in `~/Library/Application Support/io.github.ikora128.TriTab`, and temporary shelf files in `~/Library/Caches/io.github.ikora128.TriTab`.

## Build from source

```sh
./scripts/setup-dev-signing.sh    # once: creates a self-signed development certificate in its own keychain
./scripts/test.sh                 # run the tests
./scripts/build-app.sh --install  # build, copy to /Applications and launch
TRITAB_DEBUG=1 /Applications/TriTab.app/Contents/MacOS/TriTab  # launch with logging
```

The Command Line Tools are enough; Xcode isn't required. With the development certificate, Accessibility access survives rebuilds. Release steps are in [docs/RELEASE.md](docs/RELEASE.md) (Japanese).

## How it works

- **Reading touches**: the private `MultitouchSupport.framework`, loaded with `dlopen` (`Sources/MTBridge`).
- **Recognizing gestures**: `Sources/TriTabCore/GestureEngine.swift`, pure logic with tests.
- **Clicks and keys**: a CGEventTap handles ⌘-click, ⌘ alone for Eisu / Kana, and scroll suppression.
- **Sending shortcuts**: CGEvent.
- **Updates**: [Sparkle](https://sparkle-project.org), with EdDSA-signed updates and a signed update feed.
- Because it uses a private framework, TriTab can't be on the Mac App Store, and a macOS update may break it until TriTab is updated.

## License

[MIT](LICENSE)
