# Echo Voice

Native, local-only macOS meeting assistant. Swift owns recordings and durable job state. Python workers perform disposable local inference. Never send meeting content to external services.

All development scratch, caches, downloaded development dependencies, and test data must remain in this project's ignored `tmp/` directory; never use system temporary locations. Tests must honor `ECHO_TEST_ROOT` or use the project `tmp/` root. Do not remove another worker's scratch files.

Preserve raw microphone and selected-app audio independently. Inference failure must never stop durable recording. Never silently widen capture to all apps or displays. User consent, single-source recording, and gated-model terms require explicit UI choices. Visual context has been retired.

Do not claim hardware, model, or endurance validation without running it. No automatic acceptance of Xcode or gated-model agreements. See README.md, CONTRIBUTING.md, and docs/USER_GUIDE.md.
