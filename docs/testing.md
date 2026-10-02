# testing

after building:

```sh
build/Mallard.app/Contents/MacOS/Mallard --test-core
build/Mallard.app/Contents/MacOS/Mallard --test-bookmarks
build/Mallard.app/Contents/MacOS/Mallard --test-favicons
build/Mallard.app/Contents/MacOS/Mallard --test-telemetry
cargo test --locked --manifest-path Blocker/Cargo.toml
```

these cover URL handling, the password CSV parser, bookmark imports, favicon handling, resource counters, and blocking rules.

## browser checks

```sh
python3 scripts/test_server.py
```

open these in Mallard:

- `http://mallard.localhost:8742/browser.html` for profile storage, ad blocking, and test autofill
- `http://mallard.localhost:8742/visual.html` for layout and long text
- `http://mallard.localhost:8742/network.html` for upload counters
- `http://mallard.localhost:8742/favicon-green.html` for favicon changes between pages

the Developer menu's autofill actions only work on this local test server and use fake values.

## Keychain checks

```sh
build/Mallard.app/Contents/MacOS/Mallard --test-vault-storage
build/Mallard.app/Contents/MacOS/Mallard --test-vault-auth
```

these create temporary test items and remove them afterward. the authentication check needs Touch ID or your Mac login password. they don't import or read your saved passwords.

passing these checks doesn't cover every website. YouTube playback, school sign-in, and payment fields inside embedded frames still need more testing.
