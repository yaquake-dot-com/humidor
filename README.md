# Humidor

A client for the [Soulseek](https://www.slsknet.org) peer-to-peer network, for macOS.

Humidor is a modified version of [Nicotine+](https://nicotine-plus.org) 3.3.10, ported from
Python to Swift: the same protocol implementation, networking, transfer queues, shares, search,
chat rooms and plugin behavior, with an interface built with SwiftUI and AppKit.

Humidor is not affiliated with the Nicotine+ project, and is not endorsed by it.

## Status

| Component | Status |
|---|---|
| Protocol messages (server, peer, file, distributed) | Ported, wire-compatible (tested against upstream) |
| Networking thread (kqueue, P2P, indirect connections, distributed network, speed limits) | Ported |
| NAT-PMP / UPnP port mapping | Ported |
| Shares scanner and database, audio metadata (TinyTag) | Ported (metadata tested against upstream) |
| Search, downloads, uploads, user browse/info | Ported |
| Chat rooms, private chat, buddies, interests, network filters | Ported |
| Plugin system and built-in plugins | Ported (plugins are compiled in) |
| Headless command line client | Ported |
| macOS user interface (SwiftUI, AppKit tables) | Ported |
| Translations | Converted from the upstream catalogs to String Catalogs |

The macOS interface covers all pages and dialogs of the GTK interface. Options that only apply to
GTK (header bar, tray icon, icon theme, tab bar positions) are left out of the preferences, and
the MPRIS "Now Playing" source is not available on macOS.

## Building

Requires Xcode 16 or later (Swift 6) and macOS 15 or later.

```sh
swift build
swift test
```

Build the application bundle (`dist/Humidor.app`):

```sh
Scripts/build-app.sh
```

Run the headless client:

```sh
swift run humidor-cli --help
```

> If the project lives in an iCloud-synced folder, `swift test` may fail to code sign the test
> bundle. Use a build folder outside iCloud: `swift test --scratch-path /tmp/humidor-build`.

## Layout

- `Sources/HumidorCore` – protocol, networking and application logic (no UI)
  - `Protocol/` – message classes and binary encoding
  - `Network/` – networking thread, sockets, port mapping
  - `Plugins/` – built-in plugins
  - `External/` – TinyTag audio metadata reader (MIT)
- `Sources/humidor-cli` – headless command line client
- `Sources/Humidor` – macOS application
  - `Widgets/` – list views (`NSOutlineView`), text views, menus, dialogs, tab bar
  - `Dialogs/` – preferences, setup assistant and other dialogs
- `Packaging/` – `Info.plist` and application icon
- `Scripts/build-app.sh` – builds the application bundle
- `Tests/HumidorCoreTests` – tests, with expected values produced by the upstream implementation

## License

This program is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version. See [LICENSE](LICENSE).

Humidor © 2026 Ivan Eresko.

Humidor is a derivative work of Nicotine+ © 2004–2025 Nicotine+ Contributors, © 2003–2004 Nicotine
Contributors, © 2001–2003 PySoulSeek Contributors. See [NICOTINE_AUTHORS.md](NICOTINE_AUTHORS.md)
for the authors of the original work, whose translations this program also uses.

Changes made in this work: the program was rewritten in Swift, the GTK interface was replaced with
one written in SwiftUI and AppKit for macOS, and the program was renamed. The application icon is
original to this work.

- TinyTag is licensed under the MIT license.
- IP2Location LITE data is licensed under CC BY-SA 4.0.
