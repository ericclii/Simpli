# Simpli

Instagram and YouTube without short-form video, on iPhone. A modified version
of [NoScroll](https://github.com/Blueturboguy07/noscroll) (AGPL-3.0), changed
from it in 2026 (see [Changes from NoScroll](#changes-from-noscroll)).

The app loads each service's mobile website in a `WKWebView` and injects a
small engine that hides or redirects the endless surfaces: Reels, Shorts,
Explore, suggested posts and ads. It keeps messages, the people you follow,
and posting. A reel sent in a DM plays on its own; you can't scroll to the next.

Also: several accounts per service, a Screen Time page with daily usage,
a home-screen widget, light and dark appearance, and YouTube picture in picture
(automatic from fullscreen, or from the floating menu).

## Layout

```
ios/NoScroll/            the app (SwiftUI shell + WKWebView wrapper)
  App/                   state, services, web screen, floating menu
  Home/                  home screen, settings, account switcher
  Web/                   WrappedWebViewController and the site scripts
  Core/                  rule bundle model and signature check, accounts
  Design/                colours, fonts, brand marks
  Resources/noscroll.js  the engine, built from engine/
  Resources/Rules/       signed rule bundles, copied from rules/
ios/NoScrollWidget/      home-screen widget (noscroll://open/<service>)
engine/                  TypeScript source of noscroll.js
rules/                   rule bundles (source of truth): selectors, routes
tools/sign-bundle.swift  signs rule bundles and copies them into the app
keys/                    private signing key (gitignored; back it up)
```

## Build

Open `ios/NoScroll.xcodeproj`. For both targets, pick your team under Signing &
Capabilities and change the bundle identifier (`com.ericli.Simpli` and
`com.ericli.Simpli.widget`) to your own. Choose a device and Run. iOS 17+; the
status-bar and scroll-edge treatment needs iOS 26.

## Changing blocking rules

Rules are data. Edit `rules/<service>.json`, then sign it; the app refuses a
bundle whose signature doesn't match its public key:

```bash
swift tools/sign-bundle.swift sign rules/instagram.json    # from the repo root
swift tools/sign-bundle.swift verify rules/*.json
```

The private key isn't in this repository. To change rules in your own build,
run `swift tools/sign-bundle.swift keygen` first: it creates your own key pair
and makes the app trust your public key instead, then sign every bundle.

Some behaviour that CSS selectors can't express lives in scripts in
`ios/NoScroll/Web/WrappedWebViewController.swift`: ending the Instagram feed at
"You're all caught up", locking DM reels and single posts, hiding the Explore
grid under the search box, hiding the "Use the app" banner, and reporting the
signed-in username for the account switcher.

## Engine

`Resources/noscroll.js` is the minified build of `engine/`
(`cd engine && pnpm install && pnpm build`, then copy `engine/dist/noscroll.js`
into `ios/NoScroll/Resources/`). Its source is kept here because the AGPL
requires shipping it with the app.

## Changes from NoScroll

- iOS only: the Android app, Screen Time shielding, sleep mode, onboarding, CI
  and the live probe harness are removed.
- A new SwiftUI shell: home carousel with per-service accounts, settings,
  Screen Time usage, floating glass menu, appearance setting.
- Instagram scripts: feed ends at "You're all caught up", DM reels and single
  posts are locked, the Explore grid is hidden under search, the app banner is
  hidden, and the username is read for the account switcher.
- YouTube picture in picture.
- The engine is trimmed to what the app uses (no telemetry, rule-health probes,
  isolation gestures or test hooks), and the rules are re-signed with a new key.

## Licence

AGPL-3.0-or-later. See [LICENSE](LICENSE). Not affiliated with Meta, Instagram,
Google or YouTube.
