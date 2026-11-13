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

```sh
python3 scripts/check_signing.py
```

this builds two different test programs with the same signing identity. the second must read the first's disposable Keychain item without an authentication prompt. it doesn't read saved browser data.

## browser checks

```sh
python3 scripts/test_server.py
```

open these in Mallard:

- `http://mallard.localhost:8742/browser.html` for profile storage, ad blocking, and test autofill
- `http://mallard.localhost:8742/visual.html` for layout and long text
- `http://mallard.localhost:8742/background.html` for the default page background
- `http://mallard.localhost:8742/network.html` for upload counters
- `http://mallard.localhost:8742/favicon-green.html` for favicon changes between pages

the Developer menu's autofill actions only work on this local test server and use fake values.

click the URL bar, type without submitting, click the page, and repeat. each return to the bar should select the full address. a second click while editing should place the cursor normally. clicking a bookmark should add a tab and keep the previous one open.

## Keychain checks

```sh
build/Mallard.app/Contents/MacOS/Mallard --test-vault-storage
build/Mallard.app/Contents/MacOS/Mallard --test-vault-auth
```

these create temporary test items and remove them afterward. the authentication check needs Touch ID or your Mac login password. they don't import or read your saved passwords.

passing these checks doesn't cover every website. YouTube playback, school sign-in, and payment fields inside embedded frames still need more testing.
