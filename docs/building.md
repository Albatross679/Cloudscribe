# Building

## Requirements

| Need | Why | Install |
|---|---|---|
| Xcode | the app is an `.xcodeproj` | App Store, then `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -license accept`, then `xcodebuild -runFirstLaunch` |
| cmake | builds `libwhisper` | `brew install cmake` |
| Rust | builds the `asian-autocorrect` dylib the bridging header imports | `curl https://sh.rustup.rs -sSf \| sh` |
| libomp | linked by `libwhisper` | `brew install libomp` |
| meson, ninja | build the `webrtc-audio-processing` echo canceller, linked statically | `brew install meson ninja` |

All of these are required even for a cloud-only build: the bridging header pulls in whisper.cpp and asian-autocorrect, so the local engine compiles regardless. This is a cost for whoever builds the app, not for whoever installs it.

## Signing

Run this once, before the first build:

```bash
./scripts/create_signing_identity.sh
```

macOS ties permission grants to an app's designated requirement. Ad hoc signing makes that requirement a bare `cdhash`, which changes on every build, so each rebuild silently voids Accessibility, Input Monitoring, Microphone, and PostEvent while System Settings still shows them enabled.

A self-signed certificate makes the requirement name the certificate instead, so grants survive rebuilds. It is user scoped, free, and needs no Apple Developer account. Check it took:

```bash
codesign -d -r- "/Applications/Cloudscribe.app"
```

A requirement mentioning `cdhash` means the identity is missing and the build fell back to ad hoc.

The app ships as bundle id `local.clouddictation.OpenSuperWhisper`, display name `Cloudscribe`, so it coexists with a stock OpenSuperWhisper install rather than sharing its preferences. If both are installed, give them different record hotkeys; the default is Option + backtick in each.

The bundle id, preferences domain, `~/Library/Application Support/OSW Cloud` folder, Keychain service and signing identity all date from the OSW Cloud name and are kept on purpose. macOS permission grants, API keys, history and settings belong to them, so renaming any of them would reset an existing install. Xcode still names its build product `OpenSuperWhisper.app` after the target; `scripts/build_app.sh` copies it to `Cloudscribe.app` before signing.

## Packaging

```bash
./scripts/make_dmg.sh
```

Produces a drag-to-install `runs/Cloudscribe.dmg`, about 8 MB. Unsigned by Apple, so it installs on the machine that built it and Gatekeeper refuses it everywhere else.

Distribution needs an Apple Developer ID, after which the same script signs, notarizes, and staples:

```bash
./scripts/make_dmg.sh "Developer ID Application: Your Name (TEAMID)" your-notary-profile
```

The DMG format is not what makes an app distributable; notarization is. Upstream ships a notarized DMG, which is why installing OpenSuperWhisper never required Xcode.

Notarization needs an Apple Developer Program membership, currently $99 a year. Nothing else substitutes: a self-signed certificate keeps permissions stable on the machine that built the app, but Gatekeeper still refuses it elsewhere. Until then a recipient must clear the quarantine flag by hand:

```bash
xattr -dr com.apple.quarantine "/Applications/Cloudscribe.app"
```

## Reproducibility

The tracked source rebuilds both the app and the DMG. Verified by cloning the repo to a clean directory and running the pipeline: all patches applied and the app built.

Clone this fork with `git clone --recurse-submodules https://github.com/Albatross679/Cloudscribe.git`. Its default branch `osw-cloud-baseline` contains the published Cloudscribe project. Upstream `develop` remains a separate preserved branch. Run `python3 scripts/patch_osw.py`, `npm test`, `scripts/test_shortcuts.sh` and `scripts/build_app.sh`. The candidate is `build/Build/Products/Release/Cloudscribe.app`. These commands do not install or launch it.

App source is tracked at `OpenSuperWhisper/` in the repository root, not in a nested clone. `build/`, `SourcePackages/`, submodule build products and `runs/` are local outputs. Upstream baseline `bef6bc0421d0c010e8f2fb4288c0d74978c8b964` is preserved in git history and recorded in `scripts/patch_osw.py`. Updating to newer upstream behavior is separate work. The personal cloud-dictation-manager now targets the active fork primary at `/Users/qifanwen/Desktop/Vault1/firstmate/projects/OpenSuperWhisper`. Its `--sync` only fast-forwards a clean `osw-cloud-baseline` tree from the fork, refusing feature branches, dirty trees and ahead/diverged commits without resets or pushes. Its `--build` only creates a root-layout candidate, without installation, app lifecycle changes or TCC resets.

The runtime plaintext credentials file is under Application Support, outside the repository and the app bundle. Do not copy it into builds, DMGs or shared archives. Packaging stages only the built app, not the user settings directory.

Two things do not come from the repo:

| Not reproducible | Consequence |
|---|---|
| `.auth-token.local` | A secret. Generate a new one and `wrangler secret put AUTH_TOKEN`. |
| The signing certificate | A new one is a new identity, so permissions need granting once more. |

Builds stamp their own version and provenance into `Info.plist` (`CFBundleShortVersionString`, `CDSourceRef`, `CDUpstreamRef`), so a binary traces back to the commits that produced it rather than reporting upstream's version.

## Local regression tests

`npm test` covers client encoders, stubbed HTTP, private local-file credential persistence, offline audio speed and the Settings engine choice without real credentials or paid requests. The engine choice test opens two small windows in its own never-activated process to check that a click which only focuses Settings cannot change the engine. After `python3 scripts/patch_osw.py`, run `scripts/test_shortcuts.sh` to test the actual pinned shortcut dispatch and mouse-event filtering with isolated test dependencies, plus fresh full patch generation, idempotent reruns and the engine selector contract. That command does not create event taps, post global input, record audio, or alter preferences. `scripts/test_echo_canceller.sh` builds the echo canceller and runs the production writer on a simulated speaker echo with a second talker, with no audio device or permission. Installed hotkey permissions and physical recorder behavior still require a GUI check.

The echo canceller is the `webrtc-audio-processing` submodule, pinned at v2.1. `scripts/build_echo_canceller.sh` builds it with meson, together with the `src/native` C wrapper and the abseil it needs, into one static `build/libecho_canceller.a`, so the app ships no extra dylib. The first build downloads abseil through the submodule's hash-checked meson wrap.

## How the patching works

`scripts/patch_osw.py` applies the Cloudscribe changes in place to the tracked root app source. It never clones, resets or replaces a nested upstream checkout. Owner provider/dashboard/credential files remain in `src/client/` and are copied into the app by the generator. Other modifications remain verified exact-string patches with idempotence sentinels. Edit owner sources or the generator rather than only a generated Swift file. Regression tests extract the pinned upstream source from git history into a temporary fixture, apply every patch twice and compare the result with the tracked app tree. See [repository-migration.md](repository-migration.md) for baseline, history and external dependency boundaries.
