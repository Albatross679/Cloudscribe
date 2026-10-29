# Cloudscribe

Cloudscribe 0.2.0 is dictation for macOS. Hold a hotkey, speak, and the text is typed into whatever app has focus. Speech is transcribed either on this Mac or by a cloud provider you choose.

It is a fork of [Starmel/OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) (MIT, see [LICENSE](LICENSE)). The original [cloud-dictation repository](https://github.com/Albatross679/cloud-dictation) is kept for history and old release downloads. See [migration boundaries](docs/repository-migration.md) and the [original upstream README](docs/upstream-readme.md).

## Engines

**Settings > Models > Engine** has one bar with four tabs.

- **Local** holds **Parakeet** and **Whisper**, which run on this Mac. Opening the tab switches nothing until you pick one of them, and only then is its model downloaded.
- **Cloudflare** calls Workers AI in your Cloudflare account directly. No Worker deploy is needed. This is the default cloud provider, and Nova-3 is its default model.
- **Hugging Face** calls Inference Providers.
- **OpenRouter** offers 28 transcription models and shows their current prices.

A line under the bar and the first item of the menu bar menu name the engine dictation uses. A click that only brings an inactive Settings window forward never changes the engine. Each cloud provider keeps its own API key, and **Test Connection** checks it. A valid key does not guarantee access to every model.

## Install

Version 0.2.0 has no prebuilt download yet. Build it from source:

```bash
git clone --recurse-submodules https://github.com/Albatross679/Cloudscribe.git
cd Cloudscribe
./scripts/create_signing_identity.sh   # once, keeps macOS permissions across rebuilds
./scripts/build_app.sh
```

The build needs Xcode, cmake, Rust, libomp, meson and ninja. It produces `build/Build/Products/Release/Cloudscribe.app`. Copy it to `/Applications/Cloudscribe.app`. See [docs/building.md](docs/building.md) for requirements, signing and packaging.

The older 0.1.0 release is still available as a [DMG](https://github.com/Albatross679/cloud-dictation/releases/download/v0.1.0/OSW.Cloud.dmg) or with `brew install --cask albatross679/tap/osw-cloud`. It does not have the 0.2.0 changes listed in [docs/release-notes.md](docs/release-notes.md).

Cloudscribe was called OSW Cloud until after 0.2.0. It keeps the old bundle id and data folders, so an installed OSW Cloud's permissions, keys, history and settings carry over. Delete `/Applications/OSW Cloud.app` after installing Cloudscribe.

## Cloudflare

1. Create a Cloudflare account if you do not already have one.
2. In the Cloudflare dashboard, open **AI -> Workers AI -> Rest API -> Create API Token**.
   <img src="attachments/workers-ai-rest-api.png" width="600" alt="Cloudflare dashboard: Workers AI page with the REST API button">
   <img src="attachments/create-api-token.png" width="600" alt="Using Workers AI REST API page with the Create a Workers AI API Token panel">
3. On a fresh launch the app walks you through creating, testing and saving the token in one window. You can also open **Settings > Models > Engine > Cloudflare** and paste only the API token.
   <img src="attachments/app-settings-direct-api.png" width="475" alt="App settings: Cloudflare engine, Direct API connection, token pasted">

Cloudflare gives 10,000 neurons per day free on every plan. See [docs/models.md](docs/models.md) for models, languages and measured cost.

### Settings worth knowing

- **Transcription > Language.** Nova-3 serves ten languages and errors on the rest. For anything else pick `whisper-turbo`.
- **Transcription > Vocabulary.** A comma separated term list, not prose, for example `R2, Kubernetes, Workers AI`. It fixes proper nouns.
- **Cloud provider > Audio speed.** Choose from `1` to `3` in steps of `0.25`. The default `1` uploads the original recording unchanged. Higher speeds keep pitch and cut billed audio minutes but lower accuracy, see [asr-compression-cost](https://github.com/Albatross679/asr-compression-cost).

## Speaker sound

Audio this Mac plays during a dictation, a video or a call, is removed from the recording, so it is not transcribed. WebRTC's echo canceller (AEC3) subtracts what the speakers played, taken from a Core Audio tap of system output, from the microphone. It is on by default under **Settings > Shortcuts > Recording Behavior > Remove speaker sound**.

It needs macOS 14.2 and **System Audio Recording** access, under System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only. Without that access, Core Audio delivers no audio to the canceller, so the app keeps the plain microphone recording it always made. The same happens whenever the canceller cannot start. Headphones need none of this.

## How keys are stored

API keys are **plaintext**, stored at `~/Library/Application Support/OSW Cloud/credentials.json`, not embedded in the app. The file is mode `0600`, its parent is `0700`, and writes are atomic. Other processes running as your Mac user and backups can still read it. This storage tradeoff was explicitly approved; keep the file private and out of git, app bundles and shared archives.

When the file is missing, the app attempts one no-prompt import of existing Keychain entries and an old Worker token already in UserDefaults. Existing Keychain entries and unrelated preferences are left untouched. Keys needing Keychain approval are not retried silently: the app shows an import notice and accepts a fresh paste. A damaged settings file is not overwritten, and save failures appear in Settings and block cloud requests until fixed. **Reload local settings** retries after a repair.

**Import keys from environment** is an explicit Settings action and never replaces an existing key. It reads `CLOUD_DICTATION_WORKER_TOKEN`, `CLOUD_DICTATION_DIRECT_API_TOKEN`, `HF_TOKEN`, and `OPENROUTER_API_KEY` from the app process environment. GUI-launched apps may not inherit your shell environment, so pasting into the selected provider's key field is usually simpler. No Mac password is collected by the app.

## Hugging Face

1. Create a fine-grained access token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens/new?ownUserPermissions=inference.serverless.write&tokenType=fineGrained) with the **Make calls to Inference Providers** permission.
2. Paste it into the key field. There is no account or endpoint to configure.

Models are `openai/whisper-large-v3-turbo` (default) and `openai/whisper-large-v3`. Those are the only two speech models the `hf-inference` provider serves warm; every other Whisper size answers "Model not supported by provider hf-inference", so the picker does not offer one.

Cost: Inference Providers bills per request against a free monthly credit allowance, with more credit on PRO. See [the pricing page](https://huggingface.co/docs/inference-providers/pricing) for current rates.

## OpenRouter

1. Create a key at [openrouter.ai/settings/keys](https://openrouter.ai/settings/keys) and add credit.
2. Paste it into the key field.

Models include the existing `openai/whisper-large-v3-turbo` (default), `openai/whisper-large-v3`, `deepgram/nova-3`, `openai/gpt-4o-mini-transcribe`, and `openai/gpt-4o-transcribe`, plus `google/gemini-3.5-transcribe`, `fish-audio/transcribe-1-pro`, `assemblyai/universal-3-5-pro`, `meta/muse-voice-transcribe-1.0`, `microsoft/mai-transcribe-2`, `qwen/qwen3-asr-1.7b`, `qwen/qwen3-asr-0.6b`, `openai/gpt-transcribe`, `elevenlabs/scribe-v2`, `elevenlabs/scribe-v2-medical`, `assemblyai/universal-3-6-pro`, `fish-audio/transcribe-1`, `google/chirp-3`, `microsoft/mai-transcribe-1.5`, `mistralai/voxtral-mini-3b-2507`, `mistralai/voxtral-mini-transcribe`, `mistralai/voxtral-small-24b-2507-stt`, `nvidia/nemotron-3.5-asr-streaming-multilingual-0.6b`, `nvidia/parakeet-tdt-0.6b-v3`, `openai/whisper-1`, `x-ai/grok-stt-1.0`, `mistralai/voxtral-mini-transcribe-3-0`, and `mistralai/voxtral-small-transcribe-3-0`. The 23 entries after the first five start in automatic language detection mode; the app does not claim model-specific language pinning or vocabulary boosting until it has a verified compatible wire option.

Cost: pay per request with no subscription, at each upstream provider's rate plus OpenRouter's fee. The picker shows each model's current OpenRouter list price, and **Compare all OpenRouter prices** under it charts every model, per audio minute or per 1M tokens. Prices are fetched without a key and cached, so they still show offline, marked possibly outdated. Every response reports its own `usage.cost`, and the [activity page](https://openrouter.ai/activity) is the authority. Recordings are capped at 25 MB and upstream providers time out after about 60 seconds.

## What each provider can do

| | Cloudflare | Hugging Face | OpenRouter |
|---|---|---|---|
| Language pinning | yes, per model | **no**, the speech pipeline rejects a language parameter | per model; 23 newer entries are auto-only |
| Vocabulary boosting | yes, on Nova-3 and Whisper turbo | **no**, the pipeline takes no decoder prompt | model/provider-specific; this app does not send optional keyterm routes |
| Audio speed | yes | yes | yes |
| LLM cleanup | yes, on Workers AI | yes, on the HF router | yes, on OpenRouter |
| Local dictation usage dashboard | dictation counts, original minutes and estimated/unknown request costs | dictation counts, original minutes and unknown costs | dictation counts, original minutes and provider-reported/unknown costs |
| Legacy neuron readout | Worker account uploads only, UTC | no, not a Cloudflare account | no, not a Cloudflare account |

Where a feature says no, the app disables the control and prints the reason next to it rather than accepting the setting and dropping it. Audio speed is applied on your Mac before the upload, so every provider honors it. The vocabulary list still reaches the cleanup pass as known spellings even where the recognizer cannot use it.

## Dictation usage

Open **Dictation usage** in the main window for separate native charts of dictation counts, original recording minutes and request costs across local engines and all cloud providers. Choose daily, weekly or monthly calendar totals, a date range and a provider filter. The Mac saves a private local ledger without transcripts, audio bytes or credentials. Reported charges, gross list-rate estimates and unknown costs remain separate, including cleanup and retries. Local inference adds minutes without a cloud API charge. Existing recordings and legacy Worker account totals are not backfilled as cross-provider history. See [docs/usage-metrics.md](docs/usage-metrics.md) for storage, rates, calendar rules and tests.

## Structure

```text
src/
├── index.js      router and auth gate
├── api/          request handling, auth, usage counter
├── core/         model registry, cleanup, vocabulary, language, metering
└── client/       the Swift engine added to OpenSuperWhisper, one file per provider

OpenSuperWhisper/ tracked app source in the upstream root layout
OpenSuperWhisper.xcodeproj/ native app project
scripts/          in-place patch, build, tests, package, signing identity
docs/             the detail
runs/             generated, gitignored
repos/            upstream checkout, generated, gitignored
```

## Docs

- [docs/release-notes.md](docs/release-notes.md) - what changed in each version
- [docs/transcription-catalog.md](docs/transcription-catalog.md) - every selectable model with dated public prices
- [docs/models.md](docs/models.md) - which model to pick, languages, vocabulary, measured accuracy and cost
- [docs/api.md](docs/api.md) - worker endpoints and parameters
- [docs/building.md](docs/building.md) - build requirements, signing, packaging, reproducibility
- [docs/usage-metrics.md](docs/usage-metrics.md) - local recording minutes, request costs, calendar dashboard and offline tests
- [docs/functionality-check.md](docs/functionality-check.md) - synthetic request checks, unavailable models, offline regressions, and recorder-test limits
