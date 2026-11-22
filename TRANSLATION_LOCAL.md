# Commet – local message translation modification

This branch (`feature/message-translation`) adds native, client-side message
translation using a self-hosted translation API (`/health`, `/languages`,
`/translate`). It is a local modification only: nothing is published.

Translation happens purely in the presentation layer. Matrix events are never
modified, and translations are never sent to Matrix, Discord or Telegram.

## Building locally (Linux)

Requirements (CachyOS / Arch):

```sh
sudo pacman -S --needed clang cmake ninja pkgconf gtk3 mpv libsecret \
  webkit2gtk-4.1 libkeybinder3 lld llvm
```

Flutter 3.47.9 (version pinned in `mise.toml`) was installed user-locally:

```sh
git clone --depth 1 -b 3.47.9 https://github.com/flutter/flutter.git \
  ~/.local/share/flutter-sdks/flutter-3.47.9
export PATH=$HOME/.local/share/flutter-sdks/flutter-3.47.9/bin:$PATH
```

Build:

```sh
cd commet
flutter pub get
dart run scripts/codegen.dart          # l10n + drift + emoji codegen
# The second flag is needed with clang >= 23 (flutter_webrtc warning).
# If a build ever ran with other flags, delete
# build/linux/x64/release/CMakeCache.txt first: CMake caches CXXFLAGS.
export CXXFLAGS="-Wno-error=uninitialized -Wno-error=unused-but-set-global"
export CFLAGS=-Wno-error=uninitialized
flutter build linux --release --dart-define PLATFORM=linux
```

Result: `commet/build/linux/x64/release/bundle/commet`. It runs directly from
that directory and does not replace the installed Commet. The installed
Commet is a Flatpak (`chat.commet.commetapp`) with sandboxed data under
`~/.var/app/`. This build stores its data in
`~/.local/share/chat.commet.commetapp.develop/` instead, so
you sign in separately (a new Matrix session/device) and the Flatpak data is
untouched. Both use the same single-instance socket name inside their own
data directory, so running both at once should work. That was not tested.

Checks:

```sh
dart format -o none --set-exit-if-changed lib unit_test   # generated files excepted
dart analyze
flutter test unit_test
```

## Configuring the translation server

1. Settings → App Settings → **Translation**.
2. Enter the server URL (for example `https://translate.example.org`). Only
   `https://` is accepted.
3. Enter the API key. It is stored in the system keyring (KWallet / ksecretd
   via the Secret Service API on KDE). It is never written to Commet's
   preference files. If no keyring is available, the key is kept in memory
   until Commet closes. The settings page says which case applies.
4. Click **Test connection**. This checks reachability and TLS, `/health`,
   API key acceptance and the language list. Model, API version and language
   count are then shown.
5. Turn on **Message translation**, and choose the default *Translate to*
   language (and optionally a fixed source language; default is automatic
   detection).

Enabling the service does **not** translate any room automatically.

## Translating

* **Single message:** right-click (desktop) or long-press (Android) a
  message → **Translate**. **Translate to…** picks another target or a fixed
  source language. Below the translated text, *Translated from Spanish ·
  Show original* switches back and forth without another request.
* **Whole Space:** Space settings → **Translation** → *On*, with optional
  target/source overrides. All rooms in the Space (and nested Spaces)
  inherit it.
* **One room:** Room settings → **Translation** (Inherit / On / Off, plus
  language overrides). The page shows the effective policy and where it comes
  from (room, Space(s), or the app default). The room's quick-access bar also
  has an **Auto-translate** toggle.

Precedence: room → nearest Space setting on every parent path → app default
(off unless "Translate all rooms automatically" is enabled). If parent Spaces
disagree, automatic translation is **off** and the room page names the
conflicting Spaces.

**Encrypted, direct and very small (≤ 3 members) rooms** are never translated
through inheritance. They need the room set to *On* plus an explicit consent
on the room page (or the consent dialog shown on first manual translation).

## Cache

Translations are cached in memory only (LRU, 2000 entries), keyed by account,
room, event, content hash, languages and server/model/version. Edits, a
language change or a different server/model never reuse old results.
**Clear translation cache** on the settings page empties it. Logging out of an
account removes its cached translations and its room/Space translation
settings. The server-side SQLite cache is not affected.

## Troubleshooting

| Status | Meaning |
|---|---|
| *The translation server is unavailable* | DNS / connection failure, or the proxy did not answer. Check the URL and that NPM and the LXC are up. |
| *secure connection … could not be verified* | Certificate problem. There is no bypass, so fix the certificate. |
| *rejected the API key* | 401 from `/languages`. Re-enter the key. Automatic translation pauses until settings change or a connection test succeeds. |
| *server is busy* | 429. The client backs off (honouring `Retry-After`, capped at 60 s) with at most 3 attempts. |
| *did not respond in time* | No answer within 130 s. The backend may still be processing it. |
| Message not translated automatically | It may contain a spoiler, code block, named link, media, or no text. Use **Translate** on it for an explanation. Automatic failures are silent by design. Use **Retry translation** from the menu. |

## Updating from upstream Commet

```sh
git fetch <upstream-remote>
git switch feature/message-translation
git rebase <upstream-remote>/main      # or merge
```

Touch points in upstream files (small, likely conflict spots):

* `lib/ui/molecules/timeline_events/events/timeline_event_view_message.dart`:
  wraps `formattedContent`.
* `lib/ui/molecules/timeline_events/timeline_event_menu.dart`: adds menu
  entries.
* `lib/ui/pages/settings/categories/{app,room,space}/settings_category_*.dart`:
  adds tabs.
* `lib/ui/organisms/room_quick_access_menu/room_quick_access_menu.dart`: adds
  the toggle.
* `lib/main.dart` (init) and `lib/client/client_manager.dart` (logout hook).
* `pubspec.yaml` (`flutter_secure_storage`), ARB files (appended keys).

Everything else lives in `lib/client/translation/`,
`lib/ui/molecules/translation/`, the two new settings pages and
`unit_test/translation/`.

## Reverting

* Disable: turn off *Message translation* in settings. Commet then behaves
  as unmodified.
* Remove the code: `git switch main` (the modification is only on this
  branch), or `git revert <commit>` on the branch.
* Remove stored data: the API key is the keyring entry
  `commet.translation.api_key`. Other settings are `translation.*` keys in
  Commet's shared preferences.
