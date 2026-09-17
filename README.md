<p align="center">
  <img src="Packaging/AppIcon.svg" width="128" alt="Humidor icon">
</p>

<h1 align="center">Humidor</h1>

<p align="center">
  A native macOS client for the <a href="https://www.slsknet.org">Soulseek</a> peer-to-peer network.
</p>

Humidor is a Swift rewrite of [Nicotine+](https://nicotine-plus.org) 3.3.10 for macOS. It keeps the
proven networking, transfer queues, shares and search behavior of Nicotine+, and replaces the GTK
interface with one built with SwiftUI and AppKit, following the macOS design guidelines.

Humidor is not affiliated with the Nicotine+ project, and is not endorsed by it.

## Features

- Search the Soulseek network, with result filters, grouping and a wishlist
- Download and upload queues with speed limits, per-folder grouping and transfer statistics
- Browse the shared files of other users, and save file lists to disk
- Share your own folders, with separate shares for buddies and trusted buddies
- Chat rooms, private chat, user profiles, buddies and interests
- Ban and ignore lists, geo-blocking and download filters
- Built-in plugins (commands, leech detector, auto-browse, spam filter and more)
- Port forwarding with UPnP and NAT-PMP
- Translations into 20 languages
- A native interface: system sidebar, toolbar, search fields, alerts and Settings window, with
  Liquid Glass on current macOS
- Mac behavior: keeps running with its window closed, counts unread private chats and mentions on
  the Dock icon, follows the system appearance, accent color and language, speaks messages with
  the system voice, and shows files in Finder
- A headless command line client

## Requirements

- macOS 15 or later
- A Mac with Apple silicon, when using the downloaded application

## Installation

Download `Humidor.zip` from the [releases page](https://github.com/yaquake-dot-com/humidor/releases),
unzip it and move `Humidor.app` to the Applications folder. Until the first release is published,
build the application from source, as described below.

The application is not notarized by Apple yet, so macOS blocks it the first time it is opened. To
open it, Control-click `Humidor.app` in Finder, choose Open, and confirm. Alternatively, run:

```sh
xattr -dr com.apple.quarantine /Applications/Humidor.app
```

## Building from source

Requires Xcode 26 or later (Swift 6, macOS 26 SDK). The application runs on macOS 15 and later.

```sh
git clone https://github.com/yaquake-dot-com/humidor.git
cd humidor
Scripts/build-app.sh
```

The application is built in `dist/Humidor.app`. Build it with the script rather than
`swift run`: SwiftPM records the wrong SDK version in the executable, which makes macOS show the
legacy appearance, and the script corrects it.

Run the tests, and the headless client:

```sh
swift test
swift run humidor-cli --help
```

## Project layout

| Folder | Contents |
|---|---|
| `Sources/HumidorCore` | Protocol, networking, transfers, shares, search, chat and plugins (no UI) |
| `Sources/Humidor` | macOS application: SwiftUI views, with AppKit list views and text views |
| `Sources/humidor-cli` | Headless command line client |
| `Tests/HumidorCoreTests` | Tests, with expected values produced by the Nicotine+ implementation |
| `Packaging` | `Info.plist` and application icon |
| `Scripts` | Build script for the application bundle |

## Status

Humidor is young. Searching, downloading, browsing shares and chatting work on the Soulseek
network. Less tested so far: uploads to other users over long sessions, port forwarding on
different routers, and the built-in plugins. Please report problems in the
[issue tracker](https://github.com/yaquake-dot-com/humidor/issues).

## License

Humidor © 2026 Ivan Eresko.

This program is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version. See [LICENSE](LICENSE).

Humidor is a derivative work of Nicotine+ © 2004–2025 Nicotine+ Contributors, © 2003–2004 Nicotine
Contributors, © 2001–2003 PySoulSeek Contributors. See [NICOTINE_AUTHORS.md](NICOTINE_AUTHORS.md)
for the authors of the original work, whose translations Humidor also uses.

Changes made in this work: the program was rewritten in Swift, the GTK interface was replaced with
one written in SwiftUI and AppKit for macOS, settings and behavior were adapted to macOS
conventions, and the program was renamed. The application icon is
original to this work.

Humidor also includes:

- TinyTag, © 2014–2023 Tom Wallroth, © 2021–2023 Mat (mathiascode), © 2020–2023 Nicotine+
  Contributors, licensed under the MIT license (see `Sources/HumidorCore/External/TinyTag.swift`)
- IP2Location LITE data, © 2001–2024 Hexasoft Development Sdn. Bhd., licensed under
  [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)
