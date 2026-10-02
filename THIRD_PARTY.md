# third-party components

Mallard uses:

- Chromium Embedded Framework and Chromium for websites
- Brave's adblock-rust for request blocking
- EasyList, EasyPrivacy, and uBlock Origin filter lists
- Brave scriptlet resources
- JetBrains Mono for the UI

CEF's version and checksum are in `dependencies.json`. Rust dependencies are pinned in `Blocker/Cargo.lock`. Filter URLs and checksums are in `Resources/blocking/manifest.json`.

The upstream licenses and Chromium credits are in `Resources/ThirdParty`. The font license is in `Resources/fonts/OFL.txt`. Filter files keep their original comments. EasyList's license information is available in its [repository](https://github.com/easylist/easylist).

Text filters can update when the app starts. Scriptlet code stays bundled with the app.
