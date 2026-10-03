# Blinkmux

Blinkmux is a personal build of Blink Shell for using tmux on an iPad. It ships to TestFlight as **Blinkmux** (`com.mitchmalone.blinkshell`, team `HXRC74AQZR`).

## Branches

Each feature or fix is its own branch off `raw`, with a PR on `mitchmalone/blink`, so it can be offered upstream on its own:

| PR | Branch | What |
| --- | --- | --- |
| #1 | `fix/xcode27-hostview` | Build fix for Xcode 27 |
| #2 | `fix/command-error-message` | Readable `CommandError` output |
| #3 | `tmux-launcher` | `tmux` picker, ssh fallback, detach returns to the picker, agent status |
| #4 | `fix/emoji-row-fit` | Emoji stay inside the grid on iOS |
| #5 | `fix/synchronized-output` | DEC 2026 synchronized output, steady row redraws |
| #6 | `fix/padding-colour` | Padding takes the grid's edge colour |

`fork-build` merges all of them, plus commits that only make sense for this build:
- Entitlements trimmed to what the fork's App Store profiles grant: no iCloud, associated domains, web browser or user fonts.
- The Blinkmux icon and name. The source icon is `fork/Blinkmux.svg`.
- This folder.

To add a branch, list it in `BRANCHES` in `fork/testflight.sh`.

## Shipping to TestFlight

```
git checkout fork-build
fork/testflight.sh
```

The script does the following:
1. Merges the branches into `fork-build`, stopping on a conflict.
2. Archives with release Xcode as build `YYYYMMDD.HHMM`.
3. Checks the archived terminal files match the tree.
4. Exports with the "Blink Fork" App Store profiles, uploads with App Store Connect API key `JTM5DPS5W7`, and waits for TestFlight processing (`fork/asc_wait.rb`).

Output goes to `build/fork/<build>/`, which is gitignored.

The scripts default to the fork's App Store Connect issuer and key IDs. Override
them with `ASC_ISSUER_ID` and `ASC_KEY_ID` when needed. These are identifiers;
the private signing key stays outside the repo at the path below.

One-time setup on a new Mac:
- `git submodule update --init` and `./get_frameworks.sh`.
- `developer_setup.xcconfig` (gitignored), copied from `template_setup.xcconfig` with:
  - `TEAM_ID = HXRC74AQZR`
  - `BUNDLE_ID = com.mitchmalone.blinkshell`
  - `GROUP_ID = com.mitchmalone.blink`
  - `CLOUD_ID` and `KEYCHAIN_ID1 = com.mitchmalone.blinkshell`
- The iPhone Distribution certificate and "Blink Fork … AppStore" profiles installed, and the API key at `~/.appstoreconnect/private_keys/`.
- Release Xcode at `/Applications/Xcode.app`. App Store Connect rejects builds from outdated Xcode betas (error 90534).

The script also handles one known problem: Homebrew's `rsync` breaks Xcode's IPA packaging, so the export step runs with the system `PATH`.

## Testing terminal changes

`term.js`, `term.css` and `hterm_all.patches.js` can be checked without the app:
1. Serve a page that loads Blink's `Resources` with a stubbed `window.webkit.messageHandlers.interOp`.
2. Call `term_init(false, true)`, write escape sequences with `term_write`, and open the page in the iPad simulator's Safari. That's the same WebKit as the app.
3. Add a `?v=` query to the script URLs so Safari doesn't serve cached copies.

In this hterm, `t.screen_.rowsArray` holds row models (`{nodes: [{txt, attrs: {bcs, …}}]}`), not DOM rows. The DOM rows are `x-screen x-row`.
