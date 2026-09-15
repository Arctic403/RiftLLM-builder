# RiftLLM-builder

Public GitHub Actions worker for building the **private** `Arctic403/RiftLLM` Android source without placing RiftLLM source, APKs, build diagnostics, or verification bundles in a public repository or public Actions artifact.

The worker is infrastructure only. It receives an exact private RiftLLM source ref, resolves it to an immutable commit SHA, checks out that private commit with a restricted fine-grained token, runs the source-owned hardening gates, builds the three Android debug APK variants, verifies the final APKs, and publishes successful outputs back to a **private RiftLLM prerelease**. Failure diagnostics are zipped and returned to a private failure prerelease.

No `actions/upload-artifact` step is allowed. The ephemeral private checkout is deleted at the end of every run.

## Privacy boundary

```text
workspace/RiftLLM
      |
      | push private source commit
      v
Arctic403/RiftLLM (PRIVATE, source-only, no Actions workflow)
      |
      | exact SHA + restricted token
      v
Arctic403/RiftLLM-builder (PUBLIC, infrastructure only)
      |
      | build + verify on ephemeral GitHub-hosted runner
      v
Arctic403/RiftLLM private prerelease
  - RiftLLM-armeabi-v7a-debug.apk
  - RiftLLM-arm64-v8a-debug.apk
  - RiftLLM-universal-debug.apk
  - RiftLLM-verification-<sha>.zip
  - build-manifest.json
  - provenance.txt
  - sha256sums.txt
```

Public workflow logs intentionally contain only coarse stage status where practical. Detailed source-validation, dependency-fetch, Gradle and APK-verification diagnostics are kept under `$RUNNER_TEMP/riftllm-private-logs` and are returned only through the private RiftLLM failure prerelease when publication is enabled.

The public runner necessarily knows the private repository name and exact commit SHA it was authorized to build; it does **not** publish private source bytes or build artifacts.

## Build gates

1. Resolve `source_ref` to an immutable SHA through the GitHub API.
2. Verify the checked-out private source has exactly that SHA and a byte-clean tree.
3. Reject the build if the private source repository contains any `.github/workflows/*` file.
4. Generate the pinned Gradle 8.13 wrapper inside the ephemeral checkout.
5. Run the exact source commit's `scripts/prebuild-check.sh`.
6. Fetch the source-pinned llama.cpp revision with `scripts/fetch-llama.sh`.
7. Build `:app:assembleDebug` using JDK 17, Android 36, Build Tools 36.0.0 and NDK 28.2.13676358.
8. Require exactly one `armeabi-v7a`, one `arm64-v8a`, and one universal APK based on their actual packaged native libraries.
9. Verify package id, absence of INTERNET permission, APK signature, 16 KiB native alignment, Java shell, native RiftLLM runtime marker and ABI payload.
10. Produce SHA-256 sums, provenance and a machine-readable build manifest.
11. Publish only to a private RiftLLM prerelease; never to a public Actions artifact.

## Required builder secret

Configure this **only in the public `Arctic403/RiftLLM-builder` repository**:

- `RIFTLLM_PRIVATE_TOKEN` — a fine-grained token restricted to `Arctic403/RiftLLM` with the minimum permissions needed to read private source and create private release assets. `Contents: read/write` is sufficient for the current checkout + prerelease flow.

The token should not grant write access to the public builder repository itself.

## Dispatch

The workflow is `workflow_dispatch` only. Inputs:

- `source_ref` — exact RiftLLM branch/tag/SHA; normally `main` or a specific commit SHA.
- `client_id` — optional local correlation string.
- `publish` — when true, success/failure outputs are returned to private RiftLLM prereleases.

Pushing RiftLLM source does **not** automatically spend builder minutes or publish an APK. Dispatch remains intentional/manual.
