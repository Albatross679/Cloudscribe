# Repository migration

OSW Cloud, since renamed Cloudscribe, now has a genuine GitHub fork at https://github.com/Albatross679/Cloudscribe (first published as Albatross679/OpenSuperWhisper), whose parent is Starmel/OpenSuperWhisper. The existing cloud-dictation repository is retained, never deleted. Archival and active-development cutover require separate approval after verified migration publication and preservation of dependent work.

## Branches and baseline

The fork's default branch is `osw-cloud-baseline`, containing the merged OSW Cloud migration. The separately preserved `develop` branch retains the complete upstream history, including c8e6fe7 and the later recording, queue, engine and cancellation refactor. The default was changed with explicit user approval after migration publication, without overwriting or force-pushing either branch.

The migration PR uses `codex/osw-cloud-migration`, based on upstream `bef6bc0421d0c010e8f2fb4288c0d74978c8b964`, with a separate `osw-cloud-baseline` PR base at that same pinned commit. This avoids a PR that silently reverts newer develop behavior. The pinned baseline is the currently installed and verified OSW Cloud app's actual upstream source, not a claim that latest upstream is integrated. Later upstream changes remain available on develop and must be integrated in separate reviewed work. After publication and the approved default-branch change, a normal clone or public repository visit selects OSW Cloud on `osw-cloud-baseline`.

## Whole-project scope

All tracked cloud-dictation files from source a1c339e4e3163a594a809893bd042a26627fb1c8 are preserved: Worker router/auth/transcription/usage, model/language/terms/cleanup code, provider requests, app engines and usage charts, credentials implementation, docs, attachments, package manifest/lock, Wrangler configuration, signing/build/package scripts and offline tests. Upstream source and submodules are retained at the pinned root layout. Generated app source is byte-identical to the previously verified pinned app tree.

The original upstream LICENSE remains at the root. The OSW Cloud modifications' MIT notice is preserved at docs/cloud-dictation-MIT.txt and NOTICE.md. Upstream README is preserved at docs/upstream-readme.md. Its Scripts directory is consolidated into scripts, retaining manage_keyboard_layouts.sh alongside the OSW tools. There is no repos/OpenSuperWhisper nested clone. Patch generation operates in place; regression tests also regenerate from the pinned git archive and compare it against the tracked root source.

Inherited GitHub CI now checks in-place patch idempotence, Node/Swift tests, shortcut tests and a non-install Release build. No CI job deploys a Worker or installs/launches the application. Local signing uses Cloud Dictation Local Signing when present. A hosted runner without that identity uses the existing ad hoc fallback solely for its disposable candidate, not the installed application.

## Dependencies and resources not automatically moved

| Dependency | Migration boundary |
| --- | --- |
| Existing cloud-dictation releases and DMG download URLs | Remain on the old repository; README intentionally preserves the working v0.1.0 URL. Release assets/metadata require separately approved publication, not a silent replacement. |
| albatross679/tap/osw-cloud Homebrew cask | Existing installer points to old release provenance. Update only after a new reviewed release exists, retaining checksum integrity. |
| External cloud-dictation-manager skill | Approved operator cutover now defaults to /Users/qifanwen/Desktop/Vault1/firstmate/projects/OpenSuperWhisper. --status --local verifies fork/root candidate paths without network or credentials. --sync fast-forwards only the clean fork default branch and preserves local work; --build produces build/Build/Products/Release/OpenSuperWhisper.app without installation or TCC changes. Historical repository targets are refused. |
| Quick Launcher | Search of local Hammerspoon Lua and quick-launcher skill found no source-path reference to cloud-dictation. Installed /Applications/OSW Cloud.app path and bundle identity do not change. |
| Worker deployment | wrangler.jsonc and Worker source are preserved byte-for-byte. Existing Worker name, routing, account resources, secrets and any dashboard Git integration do not migrate with git. No deployment, secret creation or account change performed. |
| GitHub secrets, variables, webhooks, environments and permissions | Repository-local configuration is not copied automatically to a fork. Only read-only metadata/name inventories were exported privately. Secret values were neither read nor copied. Reconfigure only with authorization. |
| Old issues, PRs, comments, reviews and release history | Remain on cloud-dictation, with private metadata exports. GitHub does not transplant PR identities/review history into another repository. |
| Old branches, local changes and worktrees | Retained in place and in the private git bundle. No resets, stashes, renames, deletion or archival of cloud-dictation. Local modified package-lock.json remains untouched. |
| Signing identity, TCC, provider credentials and application data | Stay in their existing local stores. Git migration does not copy them. Same application identity and non-install build preserve installed behavior; no permissions reset. |

## Private recovery evidence

The task's private runs/migration directory contains a verified `cloud-dictation-all.bundle` covering old local/remote refs and tags, the primary's uncommitted binary diff, a ref inventory and issues/PR/comment/review/release/configuration metadata exports. Directory mode is 0700; bundle and exports are 0600. These are not committed or shipped in the app. The old repository itself also remains intact.

Recover git history into a separate empty location with `git clone cloud-dictation-all.bundle recovered-cloud-dictation`, then inspect the exported refs and selectively restore branches. The separately saved primary-uncommitted.patch restores the captured local package-lock change onto its corresponding base. Metadata exports preserve provenance, not executable commands or automatic issue recreation. Preserve the private export before worktree cleanup. No runtime credentials, user audio or usage ledger are included.
