# Verification Baseline

Recorded on 2026-08-19 before the stabilization work began.

| Check | Result | Evidence |
|---|---|---|
| `Scripts/verify-build.sh` | PASS | Debug executable built successfully. |
| `swift test --build-path .build-test-baseline` | FAIL | SwiftPM reported `no tests found`. |
| `Scripts/verify-strict-concurrency.sh` | FAIL | Timer callbacks in `TouchLabView` and `TouchLabViewController` called main-actor methods from nonisolated closures. |

Known product and verification gaps at baseline:

- Hot-cue key handlers and marker storage exist in the UI, but no deck storage or seek operation is wired to them.
- Track loading and waveform calculation run synchronously after the open panel returns.
- UI and the audio render callback directly share playback, scratch, and position state without an explicit synchronization boundary.
- Build success does not verify real trackpad gestures, audio output, split cue, latency, or long-running stability on a MacBook.
