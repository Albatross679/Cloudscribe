# Attribution

## This project is a fork of OpenSuperWhisper

**[Starmel/OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper)** — MIT License, Copyright (c) 2024 OpenSuperWhisper.

Everything a dictation app actually has to get right comes from that project: the global hotkey, the audio recorder, the microphone handling, pasting into the focused application, the transcription history, the settings interface, and the local Whisper and Parakeet engines. This fork adds Cloudflare Direct/Worker, Hugging Face and OpenRouter providers, local credential handling, usage charts, shortcut refinements and the Cloudflare Worker service. Cloudscribe modifications retain their MIT notice in [docs/cloud-dictation-MIT.txt](docs/cloud-dictation-MIT.txt).

The repository is a genuine GitHub fork retaining upstream history and its root app layout. `scripts/patch_osw.py` applies the Cloudscribe owner-source changes in place, without a nested clone. The installed behavior remains based on upstream bef6bc0; newer upstream development remains on develop and is not integrated by this migration. The original upstream README is preserved at [docs/upstream-readme.md](docs/upstream-readme.md).

If you want a dictation app that runs entirely on your own machine, use OpenSuperWhisper directly. It is the better choice for most people, and it ships a notarized installer.

### OpenSuperWhisper license

MIT requires that its copyright notice and permission notice travel with any
substantial portion of the work, so upstream's license is reproduced in full:

```
MIT License

Copyright (c) 2024 OpenSuperWhisper

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Bundled through the upstream build

The application links these projects, which are pulled in by the upstream Xcode project and its submodules:

| Project | License | Copyright |
|---|---|---|
| [whisper.cpp](https://github.com/ggerganov/whisper.cpp) | MIT | 2023-2026 The ggml authors |
| [autocorrect](https://github.com/huacnlee/autocorrect) | MIT | 2020 Jason Lee |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache 2.0 | FluidInference |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | 2015-2025 Gwendal Roué |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | MIT | Sindre Sorhus |

## Bundled by Cloudscribe

| Project | License | Copyright |
|---|---|---|
| [webrtc-audio-processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) | BSD 3-Clause, full text in its `COPYING` | 2011 Google Inc., The WebRTC project authors |
| [Abseil](https://github.com/abseil/abseil-cpp), built by the above | Apache 2.0 | The Abseil Authors |

Both are linked statically into the app for speaker echo cancellation.

## Models

Transcription runs on Cloudflare Workers AI. The models are operated by Cloudflare and are not distributed with this software:

- **Deepgram Nova-3**, proprietary, via `@cf/deepgram/nova-3`
- **OpenAI Whisper**, MIT, via `@cf/openai/whisper-large-v3-turbo`, `@cf/openai/whisper`, and `@cf/openai/whisper-tiny-en`

Deepgram's Keyterm Prompting, which this project uses for vocabulary boosting, is Deepgram's feature and documented at [developers.deepgram.com](https://developers.deepgram.com/docs/keyterm).
