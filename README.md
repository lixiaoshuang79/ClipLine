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

| | |
|---|---|
| ![dark mode](docs/images/panel-dark.png) | |

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

Locally built apps are ad-hoc signed. To paste automatically, grant Accessibility permission the first time you click a card (System Settings → Privacy & Security → Accessibility); without it, clicking a card only copies to the clipboard. `scripts/make-dmg.sh` packages a distributable DMG.

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
| Launch at login | Menu-bar icon (right-click) → 登录时启动 |
| Clear history | Menu-bar icon (right-click) → 清空历史 (pinned cards are kept) |

> The interface is currently in Simplified Chinese. Localization contributions are welcome.

## Data & privacy

- History: `~/Library/Application Support/ClipLine/history.sqlite` (directory 0700, files 0600). Up to 500 items with a 256 MB image budget; oldest items are evicted first.
- OCR runs entirely on-device using the Vision framework. Nothing ever leaves your Mac.
- Clips flagged concealed / transient / auto-generated (the `org.nspasteboard` conventions) are dropped before any data is read, and the storage layer refuses them again.

## Known limitations

- Dragging *multiple* files out delivers one of them (an `NSItemProvider` limitation); single files and folders are fine.
- After rebuilding or reinstalling, the Accessibility grant may need to be re-checked (ad-hoc signing).
- OCR text becomes searchable a second or two after an image is captured.

## Credits & license

The clothesline panel, clothespin and overall visual language are adapted from [Tendedero](https://github.com/alejandrobujan/tendedero) (MIT). The clipboard-capture and paste mechanics draw on [Maccy](https://github.com/p0deje/Maccy) (MIT). Full third-party notices are in [ATTRIBUTION.md](ATTRIBUTION.md) and [NOTICE](NOTICE).

ClipLine is licensed under the [Apache License 2.0](LICENSE).
