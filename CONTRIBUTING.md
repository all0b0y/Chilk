# Contributing to Chilk

Thanks for looking under the hood. Chilk is a native macOS app; this page covers building it, testing it and sending
changes.

## Requirements

- macOS 26 or later, Apple silicon.
- Xcode 26 (26.2 is what the project is built with).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`. The Xcode project is generated from
  `project.yml` and is not checked in.
- [uv](https://docs.astral.sh/uv/), only to build the DMG (it runs `dmgbuild`).
- For the brain at runtime: [Codex](https://github.com/openai/codex) (`brew install --cask codex`) and a ChatGPT
  account.

## Build and run

```sh
scripts/build.sh                         # Debug build → build/DerivedData/Build/Products/Debug/Chilk.app
scripts/run.sh                           # rebuild and (re)launch
CONFIGURATION=Release scripts/build.sh   # Release build
scripts/release.sh                       # clean Release build → dist/Chilk-<version>.dmg + dist/SHA256SUMS.txt
```

Chilk lives in the menu bar (a leaf) and at the edge of the screen; it has no Dock icon.

## Tests

```sh
cd ChilkKit && swift test     # the packages: character, needs, brain client, ears, Apple adapters
scripts/test.sh               # the same, then regenerates the AppIcon from the renderer
```

Most logic lives in `ChilkKit` and is tested there; the app target (`Chilk/`) wires it to AppKit.

## Signing

By default the app is signed ad-hoc ("Sign to Run Locally"): no Apple account is needed, but macOS asks for the
microphone, Reminders, Calendar and Notes again after every rebuild. To keep those permissions across rebuilds, sign
with a stable identity of your own — for example a self-signed code-signing certificate made in Keychain Access →
Certificate Assistant → Create a Certificate (type: Code Signing) — and name it in `Config/Signing.local.xcconfig`
(gitignored):

```
CHILK_CODE_SIGN_IDENTITY = My Code Signing Certificate
CHILK_DEVELOPMENT_TEAM =
```

`scripts/release.sh` refuses an ad-hoc build unless `ALLOW_ADHOC=1`. The app uses the hardened runtime; each permission
it asks for needs its entitlement in `Chilk/Resources/Chilk.entitlements`.

## Layout

| Path | What is there |
|---|---|
| `Chilk/` | The app: AppKit/SwiftUI windows, the tray, controllers that connect the packages |
| `ChilkKit/Sources/ChilkCore` | Pure logic: the character simulation, needs and the escalation ladder, planner, chats |
| `ChilkKit/Sources/ChilkRender` | Drawing the character (Core Graphics, a Core Animation rig) |
| `ChilkKit/Sources/ChilkEars` | Microphone, voice activity (vendored libfvad), wake word (WhisperKit), dictation |
| `ChilkKit/Sources/ChilkBrain` | Codex app-server client, Chilk's isolated Codex profile and tools |
| `ChilkKit/Sources/ChilkApple` | Reminders, Calendar, Notes and Clock adapters |
| `ChilkKit/Sources/chilk-render` | Renders the AppIcon, review previews and the DMG background |
| `ChilkKit/Sources/chilk-voice` | Voice and brain checks without the app |
| `scripts/` | Build, run, test, release |

The interface is in Russian; every string is in the String Catalog `Chilk/Resources/Localizable.xcstrings`.

## Pull requests

- Small fixes (bugs, typos, docs) — open a pull request directly.
- New features, bigger changes and new dependencies — open an issue first so we can agree on the approach.
- Keep the tests green (`swift test`) and the Debug and Release builds free of new warnings.

By contributing you agree that your contribution is licensed under the [Apache License 2.0](LICENSE), like the rest of
Chilk.
