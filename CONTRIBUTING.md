# Contributing

Use an Apple Silicon Mac with Xcode (including the Metal compiler), XcodeGen, and uv. Accept Apple's agreements yourself. Keep scratch, development downloads, caches and generated data in this repository's ignored `tmp/`. Never run tests against a real meeting library.

```sh
./scripts/build.sh
./scripts/test.sh
```

The build uses `Package.resolved`, `service/uv.lock`, the separate hashed Community lock and the pinned model catalog. `scripts/environment.sh` keeps build scratch local. The default build is a development build. Release packaging uses `scripts/build-release-runtime.sh`, `scripts/build.sh`, and `scripts/package.sh` after qualification.

For focused Swift checks, pass Xcode test selectors, for example:

```sh
./scripts/test.sh -only-testing:EchoVoiceTests/ProductionMeetingTests
```

This also runs the fast script and service checks. Hardware/model tests that need provisioning must be enabled deliberately. Never mark an unexecuted hardware check passed. Current local ASR fixtures live in ignored `test-fixtures/ami-meeting-corpus`; do not redistribute them. Use `scripts/run-model-benchmarks.sh --help` for manual model-specific comparisons.

## Architecture

- `EchoCore`: transactional SQLite/FTS state, immutable processing selections, recovery, transcript versions, annotations and exports.
- `EchoCapture`: selected process taps, AVAudioEngine microphone capture, bounded preallocated callback queues.
- `EchoRuntime`: app-owned worker lifecycle, bounded audio windows, durable scheduling and grouping.
- `EchoIntelligence`: native MLX and local Ollama notes, evidence validation.
- `EchoVoice`: SwiftUI/AppKit workspace, input selection and synchronized playback.
- `service/echo_service`: narrow authenticated loopback API and disposable Python inference workers.

Recording must never depend on inference success. Do not widen capture scope, silently change selected models, infer real speaker identity or send content to external providers. Database changes need migration and recovery tests. Audio callbacks must not allocate, lock, write files or schedule tasks.

Send focused changes with the problem, changed behavior and actual test evidence. Preserve dependency notices when adapting upstream code. Do not include credentials, real meeting content, local absolute paths or private benchmark output in commits.
