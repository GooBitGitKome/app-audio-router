# Agent Instructions

This document provides mandatory operational instructions for AI coding agents modifying or analyzing this repository.

---

## 1. Pre-Modification Checklist

Before modifying this repository, you MUST:

1. Read `README.md`.
2. Read `docs/specification.md`.
3. Read `docs/architecture.md`.
4. Read `CONTRIBUTING.md`.
5. Check `CHANGELOG.md`.
6. Inspect relevant source files in `Sources/`.
7. Inspect relevant unit tests in `Tests/`.

---

## 2. Core Principles

- **No Undocumented Assumptions**: Do not assume unverified CoreAudio or system behaviors. If behavior cannot be verified, state it as `UNKNOWN` or `TBD`.
- **No Invented Requirements**: Never invent features, constraints, or bug fixes not requested by the user or specified in `docs/specification.md`.
- **Preserve Existing Behavior**: When fixing a bug or adding a feature, identify all affected modules and ensure existing functionality is not broken.
- **Single Source of Truth**: The repository files (code, tests, docs) are the sole source of truth. Never rely on assumptions carried over from previous chat memory without checking the codebase.

---

## 3. Strict Prohibitions (Never Do)

1. **NEVER** commit API keys, secrets, tokens, credentials, or personal information.
2. **NEVER** execute blocking locks (`NSLock`), dynamic memory allocations, or unbounded loops inside real-time CoreAudio `IOProc` callbacks.
3. **NEVER** remove self-process exclusion from `ProcessTap.createGlobalTap()` — this creates a catastrophic feedback loop that destroys audio output.
4. **NEVER** silently change public behavior or API signatures without updating `docs/specification.md` and `CHANGELOG.md`.
5. **NEVER** fabricate test results or claim a test passed without actually running it and observing exit code 0.
6. **NEVER** modify production code solely to satisfy a documentation format requirement without technical justification.

---

## 4. Epistemological Classification Standard

When explaining codebase status or proposing changes, AI agents must clearly distinguish statements using these categories:

- **[FACT]**: Directly verified from repository code, configuration files, Git history, or actual command outputs.
  - *Example*: "[FACT] `ProcessTap.swift` excludes own process object IDs obtained via `getProcessObjectIDs()`."
- **[INFERENCE]**: A reasonable technical deduction based on verified facts, but not directly stated.
  - *Example*: "[INFERENCE] The sample rate mismatch caused buffer underruns because the tap produced 44.1k frames while the renderer consumed 48k frames."
- **[PROPOSAL]**: A recommended future change or architectural improvement.
  - *Example*: "[PROPOSAL] Introduce a GitHub Actions workflow to run `swift test` on every pull request."
- **[UNKNOWN]**: Information that cannot be determined with current repository data and requires confirmation.
  - *Example*: "[UNKNOWN] Whether BlackHole or ZoomAudioDevice will be present on the target end-user Mac."

---

## 5. Post-Modification Checklist

After modifying code:

1. **Build**: Run `swift build` (and `./scripts/package_app.sh` if release artifacts are affected).
2. **Test**: Run `swift test` and report actual execution results.
3. **Verify Pipeline**: For audio routing changes, run `swift run AppAudioRouterCLI diagnose` and `test-tone`.
4. **Update Docs**:
   - Update `docs/specification.md` if behavior changed.
   - Update `docs/architecture.md` if components or data flows changed.
   - Update `CHANGELOG.md` under `[Unreleased]` for user-visible changes.

## Rust coexistence

For changes under `crates/`, read `docs/rust-migration.md`, run Cargo formatting, Clippy and workspace tests, and retain the Swift checks during migration. Use `AAR_BACKEND=rust ./scripts/package_app.sh` for Rust artifact changes. Hardware acceptance is opt-in and serial; do not disturb another instance's virtual microphone. Do not remove Swift or change the default backend before the documented hardware/UI gates pass. Rust callbacks obey the same no-allocation/no-wait rules as Swift callbacks. The `objc2` binding family and CLI `libc` signal handling are approved migration dependencies; additional dependencies require technical justification.
