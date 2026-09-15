# Nicotine+ for Swift

A Swift port of [Nicotine+](https://nicotine-plus.org), the graphical client for the
[Soulseek](https://www.slsknet.org) peer-to-peer network.

The goal is a faithful port of Nicotine+ 3.3.10: the same protocol implementation, networking,
transfer queues, shares, search, chat rooms and plugin behavior, written as idiomatic Swift for
macOS and iOS.

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
| SwiftUI user interface | Not started |
| Translations | `.mo` catalogs included, String Catalog conversion pending |

## Building

Requires Xcode 16 or later (Swift 6).

```sh
swift build
swift test
```

Run the headless client:

```sh
swift run nicotine --help
```

> If the project lives in an iCloud-synced folder, `swift test` may fail to code sign the test
> bundle. Use a build folder outside iCloud: `swift test --scratch-path /tmp/nicotine-swift-build`.

## Layout

- `Sources/NicotineCore` – protocol, networking and application logic (no UI)
  - `Protocol/` – message classes and binary encoding
  - `Network/` – networking thread, sockets, port mapping
  - `Plugins/` – built-in plugins
  - `External/` – TinyTag audio metadata reader (MIT)
- `Sources/nicotine` – headless command line client
- `Tests/NicotineCoreTests` – tests, with expected values produced by the upstream implementation

## License

This program is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version. See [LICENSE](LICENSE).

This is a derivative work of Nicotine+ © 2004–2025 Nicotine+ Contributors, © 2003–2004 Nicotine
Contributors, © 2001–2003 PySoulSeek Contributors. See [NICOTINE_AUTHORS.md](NICOTINE_AUTHORS.md).

- TinyTag is licensed under the MIT license.
- IP2Location LITE data is licensed under CC BY-SA 4.0.
