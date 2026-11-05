<div align="center">

# OpenSuperWhisper

**Speak, and it types. In any app on your Mac. Free, open source, on-device.**

[![Website](https://img.shields.io/badge/Website-opensuperwhisper.com-A94327?style=for-the-badge)](https://opensuperwhisper.com)
[![Latest release](https://img.shields.io/github/v/release/my-monkeys/OpenSuperWhisper?style=for-the-badge&color=0a8f57)](https://github.com/my-monkeys/OpenSuperWhisper/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-969696?style=for-the-badge)](LICENSE)

Hold a shortcut, speak, let go: your words land where you were typing.
Five transcription engines, four of them fully on-device. No subscription, no account, no telemetry.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/home-dark.png">
  <img src="docs/screenshots/home-light.png" width="820" alt="OpenSuperWhisper's home screen: a greeting with the shortcut, the active model, and the feed of recent dictations grouped by day, with the record button at the bottom" />
</picture>

</div>

> **Community fork maintained by [My-Monkey](https://my-monkey.fr)**, started from
> [`Starmel/OpenSuperWhisper`](https://github.com/Starmel/OpenSuperWhisper) (MIT), which is still
> developed on its own side. Merged work credits its original authors. Compare the engines on real
> benchmarks at [opensuperwhisper.com](https://opensuperwhisper.com).

## Install

```sh
brew install --cask my-monkeys/tap/opensuperwhisper
```

> ⚠️ Use the full `my-monkeys/tap/` path. The bare name `opensuperwhisper` is the homebrew-cask
> entry for the original project, which still serves its 0.1.0, not this fork.

You can also download the latest **notarized** `.dmg` from
[Releases](https://github.com/my-monkeys/OpenSuperWhisper/releases), or
[build from source](#building-from-source).

**Requires** macOS 14 (Sonoma) or later, on Apple Silicon or Intel. Homebrew picks the right build.
The Intel build has Whisper, Parakeet and the remote engine; SenseVoice needs Apple Silicon, and
Apple Speech and Apple Intelligence need macOS 26.

The first launch walks you through four short steps: your shortcut, a model, the two macOS
permissions (microphone, and Accessibility to type into other apps), and a first dictation to try it.

## Everyday use

- ⌨️ **One shortcut, your way.** A key combination, a modifier on its own (Right ⌥, Fn…), two
  modifiers together, or a mouse button. Hold to talk and release to insert, or tap to start and
  tap again to stop. Extras: lock a long dictation with Space, dictate and press Return in one go,
  paste the last dictation again.
- 💬 **Watch it as you speak.** With Parakeet, the words appear live in the recording bubble (in a
  capsule of their own next to the waveform, with Liquid Glass). Say a **stop phrase** ("over and out") to end the
  dictation hands-free, and optionally press Return after it.
- 📍 **A bubble where you want it.** Near the cursor, at an edge of the screen, docked in the notch
  (a drawn one on Macs without), or wherever you drag it. Liquid Glass on macOS 26. Choose which
  elements it shows: blinking dot, waveform, label, Stop and Cancel buttons.
- 🏠 **Home.** Every dictation, grouped by day, with the app it went to and the model that wrote it.
  Filter dictations, imported files or errors, search everything with ⌘K, copy, play back, or run a
  dictation again with another model. A failed transcription keeps its audio and a retry button.
- 🎙️ **A microphone you can check.** The microphone menu on Home and in Settings shows a live input
  level, with the input volume right under it, so a mic that's too quiet is easy to spot and fix.
  Dictations recorded far too quiet are lifted before transcription.
- 📁 **Files too.** Drop audio files on the window or use **Import**, and they queue up.
- 🌍 **Your language.** About 99 languages with auto-detect, or follow your keyboard layout.
  Translation to English with Whisper. The interface is in English, French, German, Spanish,
  Italian, Portuguese (BR), Vietnamese and Simplified Chinese, light or dark.

## Five engines

| Engine | Runs | Best for |
|---|---|---|
| **Parakeet** ([FluidAudio](https://github.com/AntinomyCollective/FluidAudio)) | On-device | Speed and live text, 25 European languages |
| **Whisper** ([whisper.cpp](https://github.com/ggerganov/whisper.cpp)) | On-device | Accuracy, about 99 languages, translation to English |
| **SenseVoice** ([sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)) | On-device | Chinese, Cantonese, English, Japanese, Korean |
| **Apple Speech** | On-device, built into macOS 26 | Nothing to download, models managed by macOS |
| **Remote** | Your server | Any OpenAI-compatible endpoint: Groq preset, LiteLLM, [speaches](https://github.com/speaches-ai/speaches), a box on your LAN |

<div align="center">
<img src="docs/screenshots/settings-models.png" width="720" alt="Settings, Models: the five engine cards, the active model, and the Parakeet models with download and use buttons" />
</div>

Browsing an engine never downloads anything, and only one model is ever active. The **Remote**
engine sends audio to the server you chose and says so plainly. It lists the server's models after a
connection test, retries network hiccups, and can **fall back to a local model** so a dictation never
just fails.

## Your words, spelled right

The **Dictionary** holds the names and terms you say often.

- **New words** help the engine recognise them (Parakeet and Whisper).
- **Corrections** rewrite what the model heard: several ways of mishearing a word can point to the
  same spelling, a rule can be a regular expression, and punctuation rules know which side to glue
  to.
- **Commands**: "new paragraph" can be a line break. **Teach punctuation** has you read a few
  sentences aloud and turns the way you say punctuation into rules.
- Every entry has a live test, so you see the result before you save.

<div align="center">
<img src="docs/screenshots/dictionary.png" width="720" alt="The Dictionary page with the entry editor open: a correction that always writes OpenSuperWhisper, with its misheard variants as chips and a live test" />
</div>

**Snippets** insert a longer text when you say a short phrase: "my email" writes the address,
"sign off" a three-line signature. They match alone or mid-sentence, the longest phrase wins, and
they are expanded after the AI formatting, so the text you wrote is the text you get.

## Clean text, per app

- 🧹 **Cleanup.** Remove hesitations (um, uh…) and keep the spacing between dictations right.
- 🤖 **Format with AI** (optional). Tidy punctuation and casing with a language model:
  - **Apple Intelligence**, on-device on macOS 26, nothing to download. Unless you picked another
    engine, it is the one used on Macs that have it.
  - The **built-in** model (Qwen2.5 1.5B or 7B, a one-time download, no server to run).
  - A local [Ollama](https://ollama.com) server, or any OpenAI-compatible endpoint.

  The instructions are yours to edit. If the model fails, misbehaves or repeats its own
  instructions, the dictation is pasted as you said it.
- 🪟 **Per app** (on the **Style** page). One line per app or website: which model to use there,
  whether to paste or type (terminals and some games prefer typing), and formatting rules for the AI
  pass, so "at Rob" becomes "@Rob" in Slack and "src slash main dot swift" becomes `src/main.swift`
  in a terminal. The model follows you when you switch apps.
- ⏯️ **While you speak.** Other apps' playback pauses (and only what was really playing resumes), or
  the system volume dips.

<div align="center">
<img src="docs/screenshots/settings-text-ai.png" width="720" alt="Settings, Text and AI: cleanup switches and the AI engine menu set to Apple Intelligence, ready on this Mac" />
</div>

## Answer your coding agents by voice

Install the plugin from Settings → Assistants and OpenSuperWhisper shows a small panel when
**Claude Code** finishes a task, needs a permission or asks you a question. Read the answer, then
reply by voice or keyboard without going back to the terminal. **Codex** works too, except for its
questions, which still wait in the terminal. **pi** and **oh-my-pi** work too, through the
[pi-opensuperwhisper](https://github.com/stibbons-ai/pi-opensuperwhisper) extension. You choose which events
show the panel and which projects it follows. With live text on, your reply appears in the panel as
you dictate it.

To answer in the terminal instead, click the terminal button in the panel's header, or press ⌘O
once the panel has focus. In [Warp](https://www.warp.dev) it opens the exact window, tab and pane
the agent runs in. Other terminals and editors come to the front, and so does the terminal holding
a tmux, zellij or screen session, without picking the pane. The panel stays on screen and the agent
keeps waiting for your answer.

<div align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/agent-panel-dark.png">
  <img src="docs/screenshots/agent-panel-light.png" width="560" alt="The answer panel: Claude Code's message with a short list, and a reply field with a microphone button" />
</picture>
</div>

## Settings that stay out of the way

Settings open over the window with ⌘, and close with Esc. Eight sections (General, Dictation,
Models, Text & AI, Appearance, Assistants, Privacy, Advanced) show the essentials first; an
**Advanced** switch in each one reveals the rest. Search finds any setting by name, in English or
in your language.

<div align="center">
<img src="docs/screenshots/settings-dictation.png" width="720" alt="Settings, Dictation: the shortcut, the cancel key, the microphone and the spoken language" />
</div>

## Private by default

On-device engines never send audio anywhere. There's no account and no telemetry. The only ways
audio or text leave your Mac are the Remote engine and a remote AI server, both of which you set up
yourself and which say so. History is yours to cap by count or age, or to turn off entirely.

## Command line

```sh
opensuperwhisper transcribe path/to/audio.wav          # text on stdout
opensuperwhisper transcribe path/to/audio.wav --json   # { "file", "text" }
```

`--model path/to/ggml-model.bin` transcribes with Whisper on that model whatever engine the app is
set to, and `--raw` ignores your prompt, dictionary and transcription settings (English, a fresh
install's defaults), so nothing you set up in the app changes the result.

Engine logs go to stderr, so it pipes cleanly: `opensuperwhisper transcribe note.m4a > note.txt`.
Set up a model in the app at least once first. A **post-record hook** can also run your own shell
command after each dictation, with the text and the audio path in environment variables and as JSON
on stdin.

## 🧪 Beta testing: we need you

Real-world testing is what makes this stable. Pre-release builds are on the
[Releases page](https://github.com/my-monkeys/OpenSuperWhisper/releases) (marked *Pre-release*).
They install alongside the stable build and never touch your auto-updates.

- 🐞 **Bugs**: [open an issue](https://github.com/my-monkeys/OpenSuperWhisper/issues/new) with your
  macOS version, the engine and model in use, and the steps to reproduce.
- 💬 **Feedback**, no account needed: **Feedback** in the app's sidebar opens a short form (it shows
  exactly what it sends), or use the one on [opensuperwhisper.com](https://opensuperwhisper.com/#feedback).

## Support the project

OpenSuperWhisper is free forever: no Pro tier, no paywall. If it saves you time, you can
[**buy the monkeys a banana on Ko-fi**](https://ko-fi.com/mymonkey). Donations keep the nonprofit
(association loi 1901) running and the open-source work alive. 🍌

## Building from source

<details>
<summary>Clone, install the toolchain, build</summary>

```sh
git clone git@github.com:my-monkeys/OpenSuperWhisper.git
cd OpenSuperWhisper
git submodule update --init --recursive
brew install cmake rust ruby
gem install xcpretty
./run.sh build
```

If something breaks, `.github/workflows/build.yml` is the CI recipe that builds the app on every
push. Maintainers: see [`docs/PUBLISHING.md`](docs/PUBLISHING.md) for the notarized release and
Homebrew flow.

</details>

## Contributing

Contributions are welcome: issues, focused PRs, or big ideas
([the last community batch](https://github.com/my-monkeys/OpenSuperWhisper/pull/21) shipped a whole
menu of features). Open items live in the
[issue tracker](https://github.com/my-monkeys/OpenSuperWhisper/issues).

How the code is laid out: `OpenSuperWhisper/` is the macOS app (UI, audio capture, text insertion,
shortcuts). `OpenSuperWhisperCore/` is a local Swift package with the transcription core shared with
a future iPhone app: engines, model managers, AI cleanup, recording storage and the queue. Its
native libraries (whisper.cpp, llama.cpp and their one ggml) come from the `libwhisper/` submodules
and are built into `OpenSuperWhisperCore/Binaries/` by `Scripts/build-native.sh`, which `./run.sh
build` calls for you. [`docs/core-extraction.md`](docs/core-extraction.md) explains the split.

Tests, after `./run.sh build`:

- the app's suite: `xcodebuild test -scheme OpenSuperWhisper -derivedDataPath build
  -clonedSourcePackagesDirPath SourcePackages -destination 'platform=macOS,arch=arm64'
  -only-testing:OpenSuperWhisperTests` (the same derived data and packages as `run.sh`);
- the core's: `Scripts/test-core.sh macos` and `Scripts/test-core.sh ios` (iOS Simulator).

Never run `swift test` in `OpenSuperWhisperCore/`: it resolves the packages on its own, without the
FluidAudio patch `run.sh` applies, and writes a `Package.resolved` nobody should commit. After a
submodule bump (`git submodule update`), run `./run.sh build` again so the native libraries are
rebuilt before Xcode resolves the packages.

## Also from My-Monkey

Two other free, open-source apps from the same collective:

| | |
|---|---|
| 🐒 **[Desktop Monkey](https://desktop-monkey.my-monkey.fr)** | A pixel-art monkey that lives on your desktop: he follows your cursor, hunts it, throws bananas at it and naps when you're away. Windows and macOS, one 6 MB file. ([source](https://github.com/my-monkeys/desktop-monkey)) |
| 📊 **[Claude Monitor](https://github.com/my-monkeys/claude-monitor)** | A macOS menu-bar app that counts your Claude Code instances and MCP servers, watches the per-user process limit and RAM, and kills a runaway swarm before it takes the Mac down. |

## License

MIT, see [LICENSE](LICENSE). Built on [whisper.cpp](https://github.com/ggerganov/whisper.cpp),
[llama.cpp](https://github.com/ggerganov/llama.cpp),
[FluidAudio](https://github.com/AntinomyCollective/FluidAudio),
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) /
[SenseVoice](https://github.com/FunAudioLLM/SenseVoice),
[autocorrect](https://github.com/huacnlee/autocorrect) and
[Sparkle](https://sparkle-project.org). 🐒
