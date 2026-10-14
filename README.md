<p align="center">
  <img src="docs/images/icon.png" width="128" alt="ClipLine icon">
</p>

<h1 align="center">ClipLine</h1>

<p align="center">
A clipboard manager for macOS that hangs your clipboard history on a clothesline.<br>
Every copy becomes a card, pegged to a line under the menu bar — tinted with the color of the app it came from.
</p>

<p align="center">
  <a href="README.zh-CN.md">简体中文</a>
</p>

![ClipLine panel](docs/images/panel-light.png)

## Highlights

- **The clothesline** — press `⌃⌥V` and a line drops down from under the menu bar with your recent copies hanging as cards. Click a card to paste it back into whatever app you were using; the panel never steals focus from it.
- **Dyed hang-tags** — each card's header is tinted with a color extracted from the source app's icon and shows that icon, so you can tell where a clip came from at a glance. Link, code, color, image and file clips get their own card styles.
- **Search as you type** — just start typing. Matching is case- and width-insensitive, space separates terms (all must match), and it covers text, file names, source app names — and **text inside images** via on-device OCR (Simplified Chinese + English).
- **Private by design** — history lives in a local SQLite database. No account, no network, no analytics. Clips marked concealed/transient by password managers are never recorded or stored.
- **Pin, drag, launch at login** — pin a card to keep it forever (brass clothespin; exempt from eviction and from "Clear History"); drag cards out into any app or drop content in; optional launch at login.
- **Tag boards** — press `⇧⌘N` (or the `＋` in the bottom panel) to create a tag and right-click any card to pin it there. Tagged cards leave the rolling history and stay put — exempt from eviction and from "Clear History"; re-copying the same content carries its tags over. Rename, recolor (8 colors) or delete tags from their right-click menu. On the clothesline, a switcher beside the search field flips between 「All」 and a single tag.
- **Bottom panel, Paste-style (optional)** — prefer something other than the line? Switch the panel style to a liquid-glass layer docked to the bottom edge of the screen, holding a row of near-square cards with source-tinted headers. Toolbar: search, clipboard history, your tags, `＋`. Same one-click paste, same no-focus-stealing.
- **Screen text capture** — press `⌃⌥O` and the screen freezes under a marquee that never dims your display; drag over any text (a live coordinate readout follows the cursor, hold `Space` to move the selection). On release the text is recognized on-device, copied, added to the line, and confirmed by a card at the top with a one-tap 「去换行」 (cut line breaks).
- **Settings window** — rebind both hot keys, choose the OCR language, toggle line-break removal, switch between auto-paste and copy-only, and set history limits.

| | |
|---|---|
| ![dark mode](docs/images/panel-dark.png) | ![screen text capture](docs/images/screen-capture.png) |
| ![screen text capture confirmation card](docs/images/screen-capture-card.png) | |

## Install

Grab `ClipLine-<version>.dmg` from the [latest release](https://github.com/lixiaoshuang79/ClipLine/releases/latest), open it, and drag ClipLine into Applications.

The app is signed with a local certificate (not notarized), so macOS will block the first launch — you'll see 「未打开"ClipLine" / Apple 无法验证…」. To allow it: **System Settings → Privacy & Security → "Open Anyway" (系统设置 → 隐私与安全性 → 在「安全性」一栏点「仍要打开」)**. On macOS 14 and earlier you can instead right-click the app → Open.

Every release is signed with the same fixed certificate, so permissions you grant once — Screen Recording for text capture, Accessibility for auto-paste — survive future updates.

Then press `⌃⌥V` to bring down the line, and grant Accessibility permission when prompted (see below).

Or build from source — see below.

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel).
- To build: Xcode (recommended) or the Swift toolchain. No third-party dependencies.

## Build & run

```sh
git clone https://github.com/lixiaoshuang79/ClipLine.git
cd ClipLine
scripts/build-app.sh          # builds build/ClipLine.app
open build/ClipLine.app
```

Locally built apps are ad-hoc signed (the build script uses a local "ClipLine Dev" signing identity when one exists in your keychain). To paste automatically, grant Accessibility permission the first time you click a card (System Settings → Privacy & Security → Accessibility); without it, clicking a card only copies to the clipboard. `scripts/make-dmg.sh` packages a distributable DMG.

## Usage

| Action | How |
|---|---|
| Show / hide the line | `⌃⌥V`, or click the menu-bar icon |
| Paste a card | Click it, or `←` `→` to select and `Return` |
| Search | Just start typing. Space separates terms; `Esc` clears the query, then closes the panel |
| Pin / unpin | Hover a card → pin button (top-right). Pinned cards get a brass clothespin and sort first |
| Remove | Hover a card → `×` (top-left) |
| Drag out | Drag any card into an editor, chat window, or Finder — the line keeps its copy |
| Drag in | Drop text / images / files onto the panel to add them to the line |
| Screen text capture | `⌃⌥O` → drag over any text (`Space` moves the selection, `Esc` / right-click cancels) |
| Settings | Menu-bar icon (right-click) → 设置 |
| Launch at login | Menu-bar icon (right-click) → 登录时启动 |
| Clear history | Menu-bar icon (right-click) → 清空历史 (pinned cards are kept) |

> The interface is currently in Simplified Chinese. Localization contributions are welcome.

## Data & privacy

- History: `~/Library/Application Support/ClipLine/history.sqlite` (directory 0700, files 0600). Up to 500 items with a 256 MB image budget; oldest items are evicted first.
- OCR runs entirely on-device using the Vision framework. Nothing ever leaves your Mac.
- Clips flagged concealed / transient / auto-generated (the `org.nspasteboard` conventions) are dropped before any data is read, and the storage layer refuses them again.

## Known limitations

- Dragging *multiple* files out delivers one of them (an `NSItemProvider` limitation); single files and folders are fine.
- OCR text becomes searchable a second or two after an image is captured.

## Credits & license

The clothesline panel, clothespin and overall visual language are adapted from [Tendedero](https://github.com/alejandrobujan/tendedero) (MIT). The clipboard-capture and paste mechanics draw on [Maccy](https://github.com/p0deje/Maccy) (MIT). Full third-party notices are in [ATTRIBUTION.md](ATTRIBUTION.md) and [NOTICE](NOTICE).

ClipLine is licensed under the [Apache License 2.0](LICENSE).
