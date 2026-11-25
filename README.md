# TriTab

**Three-finger tab control for Mac** ／ [日本語](README.ja.md)

TriTab is a small menu bar app that lets you switch, close, reopen and open browser tabs with trackpad gestures. It's free and open source (MIT).
It uses about 13 MB of memory while running (BetterTouchTool: about 48 MB).

## Install

- **DMG**: download the latest `TriTab-x.y.z.dmg` from [Releases](https://github.com/iKora128/tritab/releases/latest), open it, and drag TriTab to Applications.
- **Homebrew**: `brew install --cask ikora128/tap/tritab`

Requires macOS 13 Ventura or later, on Apple silicon or Intel. TriTab is signed with a Developer ID, notarized by Apple, and keeps itself up to date. If you allow automatic installation, updates go in while you're not using your Mac, and TriTab restarts itself in about a second.

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
- **Notch Shelf**: drag a file or an image from your browser and nudge it upward, and a shelf slides out of the notch to hold it for later. As you get close to the top, it opens wide so you can just let go. Hovering over the notch opens it too.
  - Files can be added two ways. **Add a Reference** leaves the file where it is; **Add a Copy** keeps a duplicate on the shelf and never touches the original. Pick one with the switch on the strip at the top of the shelf (beside the notch) or in Settings. While dragging, hold ⌥ to add a copy or ⌘⌥ to add a reference instead. A badge on each item shows which one it is. Files in temporary folders (such as the screenshot thumbnail) are about to disappear, so they're always added as copies.
  - Images from your browser are saved on the shelf as image files (TriTab takes the file the browser writes out). Links become .webloc files you can double-click to open in your browser, and text becomes a note. For links and text, bring them all the way to the notch to open the shelf, so it doesn't pop up every time you drag a tab or some text.
  - Several files dropped at once become one stack, shown as stacked cards with a count. Dragging the stack out takes all of its files together. Right-click › Ungroup splits it into separate items.
  - Dragging an item out moves it and takes it off the shelf: a reference moves the original file, a copy moves the shelf's duplicate. Hold ⌥ to drop a duplicate instead and keep the item. Dropping onto another disk, or into an app such as Mail, also leaves a copy and keeps the item.
  - ⌘-click, ⇧-click or ⌘A selects several items to drag at once. Right-click for Open, Quick Look, Show in Finder, Make a Copy on the Shelf, Ungroup and Remove from Shelf.
  - While it's open, ⌘V adds what's on the clipboard: files the way the switch says, images as image files, links as .webloc files, and text as a note.
  - If you later move a referenced file in Finder, you can still open it from the shelf. If you delete it or move it to the Trash, the item gets a mark.
  - With **Remove Old Items** in Settings, items leave the shelf, oldest first, after 1 day, 3 days, 1 week or 1 month (off by default). Copies and notes go to the Trash, so you can get them back. Hover over an item to see when it was added and when it will be removed.
- **Swipe while dragging to move to the next desktop**: while you drag a window or file with one finger held down, swipe left or right with three other fingers (four in 4-finger mode) to move to the next desktop. The window you're holding comes along, and a file can be dropped on the new desktop. Swiping left moves to the desktop on the right, the same direction as macOS's own swipe. Keep holding and swipe again to move further.
  - TriTab uses Mission Control's "Move left a space" and "Move right a space" shortcuts (⌃← / ⌃→). If they're turned off in System Settings › Keyboard › Keyboard Shortcuts… › Mission Control, TriTab tells you.
  - Tab gestures are paused while you're dragging.
  - If you use Three Finger Drag, set TriTab to four fingers to use this. In 3-finger mode TriTab can't tell your swipe apart from the drag itself.
- **Five-finger swipe up to sleep**: choose in Settings whether it sleeps just the display or the whole Mac (off by default).

## Settings

Choose Settings… (⌘,) from the menu bar icon. The settings window runs in its own process and quits when you close it, so the always-running part of TriTab stays small.

## Privacy

- TriTab reads trackpad touches and keyboard and mouse events on your Mac only to recognize gestures and shortcuts. Nothing is recorded or sent anywhere.
- The only network access is the update check. TriTab downloads `https://github.com/iKora128/tritab/releases/latest/download/appcast.xml` once a day if you allow automatic checks (it asks on the second launch), or when you choose Check for Updates…. There is no analytics and no system profiling.
- Your data stays on your Mac: settings in `~/Library/Preferences/io.github.ikora128.TriTab.plist`; Notch Shelf notes, the list of shelf items, and the copies you put on the shelf (including images and links you paste or drop) in `~/Library/Application Support/io.github.ikora128.TriTab`. Copies and notes you remove from the shelf go to the Trash. For a reference, TriTab only remembers where the file is (as a bookmark) and never moves or deletes it unless you drag the item out.
- When you drop an image from your browser, TriTab doesn't download anything itself. It only takes the file your browser writes out.

## Build from source

```sh
./scripts/setup-dev-signing.sh    # once: creates a self-signed development certificate in its own keychain
./scripts/test.sh                 # run the tests
./scripts/build-app.sh --install  # build, copy to /Applications and launch
TRITAB_DEBUG=1 /Applications/TriTab.app/Contents/MacOS/TriTab  # launch with logging
```

The Command Line Tools are enough; Xcode isn't required. `build-app.sh` signs with your Developer ID Application certificate if you have one, and otherwise with the development certificate. Either way, Accessibility access survives rebuilds. macOS remembers only the signature you last allowed for each app, so if you switch between builds signed differently, such as the released TriTab and a build signed with the development certificate, remove TriTab from the Accessibility list in System Settings and allow it again. Release steps are in [docs/RELEASE.md](docs/RELEASE.md) (Japanese).

## How it works

- **Reading touches**: the private `MultitouchSupport.framework`, loaded with `dlopen` (`Sources/MTBridge`).
- **Recognizing gestures**: `Sources/TriTabCore/GestureEngine.swift`, pure logic with tests.
- **Clicks and keys**: a CGEventTap handles ⌘-click, ⌘ alone for Eisu / Kana, scroll suppression, and noticing when you're dragging.
- **Sending shortcuts**: CGEvent.
- **Updates**: [Sparkle](https://sparkle-project.org), with EdDSA-signed updates and a signed update feed.
- Because it uses a private framework, TriTab can't be on the Mac App Store, and a macOS update may break it until TriTab is updated.

## License

[MIT](LICENSE)
