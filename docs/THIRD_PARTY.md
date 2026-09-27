# Third-party components

Echo Voice assembles existing local speech and language-model libraries. Their respective authors retain their copyrights and license terms.

## Native dependencies

`Package.resolved` is the complete immutable Swift dependency graph. Direct dependencies are GRDB.swift 7.11.1, MLX Swift LM 3.31.4, and swift-transformers 1.3.0. The packaging script copies license, notice, and source revision files from every resolved checkout into `Echo Voice.app/Contents/Resources/Notices`, including nested vendored notices.

## Managed speech environment

`service/uv.lock` fixes Python dependencies and distribution hashes. The developer-only runtime builder verifies the uv 0.11.21 archive and the VoiceStudio source archive at commit `7ec803afa7c94ccf96973edcda58debe9b145693`. VoiceStudio's complete source archive, including its license, remains under `Contents/Resources/EchoRuntime/vendor/VoiceStudio` in production bundles. Installed Python distribution metadata and licenses remain in `Contents/Resources/EchoRuntime/speech/lib/python3.11/site-packages` (and the isolated `community` environment).

Only VoiceStudio speech components are imported. Echo Voice does not expose its dubbing, cloning, provider, or sharing interfaces. Relevant speech dependencies include MLX Whisper, pyannote.audio, PyTorch, and WebRTC AEC3 through pywebrtc-audio 0.2.0. The latter includes upstream WebRTC notices in its distribution metadata.

## Models

The exact repositories, immutable revisions, expected filenames, sizes, and hashes are recorded in `service/models.json`. Model files are downloaded only after the user chooses setup. They are not bundled in the installation image.

- Whisper large-v3-turbo: https://huggingface.co/mlx-community/whisper-large-v3-turbo
- Qwen3 4B: https://huggingface.co/mlx-community/Qwen3-4B-4bit
- Gemma 4 E4B: https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit
- GPT-OSS 20B: https://huggingface.co/mlx-community/gpt-oss-20b-MXFP4-Q8
- Community-1: https://huggingface.co/pyannote/speaker-diarization-community-1
- pyannote pipeline: https://huggingface.co/pyannote/speaker-diarization-3.1
- pyannote segmentation: https://huggingface.co/pyannote/segmentation-3.0
- WeSpeaker embedding: https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM

Gated model access requires the user's acceptance on Hugging Face. A read token is supplied to setup through standard input and is excluded from inference. Model terms apply independently of application code. Consult each pinned repository's model card and license before redistributing weights.

## Additional local speech components (2026-09-21)

- `sherpa-onnx` 1.13.8, Apache-2.0: https://github.com/k2-fsa/sherpa-onnx
- `silero-vad` 6.2.0, MIT: https://github.com/snakers4/silero-vad . Speech detection uses the model bundled in the locked package; no inference-time model download.
- ONNX Runtime 1.24.3, MIT, the separate `onnxruntime` wheel: https://github.com/microsoft/onnxruntime . `sherpa-onnx-core` also vendors `libonnxruntime.dylib`. That file is not this wheel. Its redistribution notice remains unresolved; see `service/runtime-notices/sherpa-onnx-core/1.13.8/PROVENANCE.txt`.
- NVIDIA `nvidia/parakeet-unified-en-0.6b`, NVIDIA Open Model License: https://huggingface.co/nvidia/parakeet-unified-en-0.6b and https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/ . Echo Voice downloads the sherpa-onnx maintainer's INT8 non-streaming ONNX conversion, repository `csukuangfj2/sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming`, revision `8c3a10fb13408c7a7054f6898958bf1c64a8d6c7`. This is the Unified English model, not Parakeet TDT. File hashes and source identity are recorded in `service/models.json`; accompanying model notices are retained with the snapshot.

Python package distributions and their license files remain in the bundled runtime; the application MIT license does not replace them. Model weights are downloaded during setup and are not bundled in the installation image.

## Update research and isolated grouping runtime

Handy commit `8f9cf53cd1410cda26beea39ff802ac306e39585` informed callback/consumer separation and speech-context settings. Echo retains its own Swift/C/Python implementation rather than bundling Handy's Tauri application. Handy is MIT, copyright 2025 CJ Pais: https://github.com/cjpais/Handy/blob/8f9cf53cd1410cda26beea39ff802ac306e39585/LICENSE.

Community-1 uses `service/community/requirements.lock`, including pyannote.audio 4.0.4, Torch/Torchaudio 2.8.0 and TorchCodec 0.7.0. Its isolated environment retains package notices. It does not replace the existing 3.1 pipeline environment.
