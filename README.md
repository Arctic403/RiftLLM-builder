# RiftLLM-builder

Public GitHub Actions worker for building the **private** `Arctic403/RiftLLM` Android source without placing RiftLLM source, APKs, build diagnostics, or verification bundles in a public repository or public Actions artifact.

The worker is infrastructure only. It receives an exact private RiftLLM source ref, resolves it to an immutable commit SHA, checks out that private commit with a restricted fine-grained token, runs the source-owned hardening gates, builds the three Android debug APK variants, verifies the final APKs, and publishes successful outputs back to a **private RiftLLM prerelease**. Failure diagnostics are zipped and returned to a private failure prerelease.

No `actions/upload-artifact` step is allowed. A development-only signing keystore is retained only as the private RiftLLM prerelease asset `riftllm-dev-signing-v1`; the public runner restores that exact key, verifies its certificate fingerprint, signs all debug APKs with it, then deletes the transient runner copy. The ephemeral private checkout, host CMake build tree, signing staging directory, verification/output directories, and detailed private logs are deleted by the always-run cleanup at the end of every run.

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

Public workflow logs intentionally contain only coarse stage status where practical. Detailed source-validation, builder source-contract, dependency-fetch, Gradle and APK-verification diagnostics are kept under `$RUNNER_TEMP/riftllm-private-logs` and are returned only through the private RiftLLM failure prerelease when publication is enabled. Early builder-contract failures write both `source-contract.log` and `failure-summary.txt`, so a rejected source shape is diagnosable from the private failure bundle instead of producing only source-integrity context.

The public runner necessarily knows the private repository name and exact commit SHA it was authorized to build; it does **not** publish private source bytes or build artifacts.

## Build gates

1. Resolve `source_ref` to an immutable SHA through the GitHub API.
2. Verify the checked-out private source has exactly that SHA and a byte-clean tree.
3. Reject the build if the private source repository contains any `.github/workflows/*` file.
4. Require the production-training/RiftPack source contract: RiftPack writer/SHA sources, qualification native lab, Kotlin qualification bridge, RiftTrainData V2 strict reader, `RiftTrainDataV2QualificationBridge`, qualification/V2/adversarial docs, `RIFTPACK_BASELINE_A.md`, `RIFT_TRAIN_DATA_V2_ADVERSARIAL_BASELINE_A.md`, preserved Hardware Target A evidence for both frozen slices, host RiftPack test, CMake wiring, JNI entry, Dev API routes, fail-closed raw qualification flags, corruption/interrupted-stage evidence markers, installed-APK evidence binding, validated four-transition trainer-sequence derivation, exact selected step-2 master/Adafactor checkpoint identities, `actualSelectedTrainerStatePackaged` evidence, real RiftTrain pack provenance, the 3 GiB qualification storage guard, current `riftPackFrozen=true` / `riftpack-v1-baseline-a` markers, and the exact V0.30.7 five-case RiftTrainData V2 adversarial parser contract including checksum-repaired reserved-index/BOS deep-invariant cases. The builder also pins the adversarial evidence file at 1,807 bytes / SHA-256 `59bf2d1695a226f585f9a04649a02e4916f7ca287e74e64e85c370681b79cd8a`.
5. Generate the pinned Gradle 8.13 wrapper inside the ephemeral checkout and run the exact source commit's `scripts/prebuild-check.sh`.
6. Configure/build the host CMake tree with `RIFTLLM_BUILD_TESTS=ON` and require CTest to pass, including `riftllm_rift_pack_v1`. Record the host CMake version and successful CTest gate in provenance.
7. Fetch the source-pinned llama.cpp revision with `scripts/fetch-llama.sh`.
8. Restore the exact development signing keystore from private RiftLLM prerelease `riftllm-dev-signing-v1`, or bootstrap it once on the first worker run, bind its SHA-256 certificate fingerprint into the build environment, and explicitly inject that keystore/alias into Gradle debug signing rather than relying on runner-default debug-key discovery.
9. Build `:app:assembleDebug` using JDK 17, Android 36, Build Tools 36.0.0 and NDK 28.2.13676358.
10. Require exactly one `armeabi-v7a`, one `arm64-v8a`, and one universal APK based on their actual packaged native libraries, and require every APK certificate SHA-256 to match the restored stable signing fingerprint.
11. Verify package id, exact version `0.30.7` / versionCode `43`, absence of INTERNET permission, APK signature, 16 KiB native alignment, MainActivity, `RiftPackQualificationBridge`, `RiftProcessDeathRecoveryBridge`, `RiftTrainDataV2Reader`, `RiftTrainDataV2QualificationBridge`, both RiftPack qualification Dev API route strings, the real selected-trainer/result/provenance DEX markers, packaged `riftPackBaselineId` plus `riftpack-v1-baseline-a`, both fixed process-death Dev API route strings, preserved-checkpoint retry evidence, raw native resume-result evidence, process-global resume-lease evidence, the frozen `rift-micro-process-death-recovery-baseline-a` identity in packaged DEX/native code, the exact native `forcedProcessDeathQualified=true` marker, both fixed RiftTrainData V2 adversarial Dev API routes, the adversarial evidence format and deep corruption markers, the existing promoted RiftTensor marker, the native RiftPack qualification format and `selected-adafactor-checkpoint-v1` markers, exact frozen checkpoint hash identities, its exported JNI entry, both shared process-death JNI entries, and the expected ABI payload.
12. Produce SHA-256 sums, provenance and a machine-readable build manifest.
13. Publish only to a private RiftLLM prerelease; never to a public Actions artifact.

## Required builder secret

Configure this **only in the public `Arctic403/RiftLLM-builder` repository**:

- `RIFTLLM_PRIVATE_TOKEN` — a fine-grained token restricted to `Arctic403/RiftLLM` with the minimum permissions needed to read private source and create private release assets. `Contents: read/write` is sufficient for the current checkout + prerelease flow.

The token should not grant write access to the public builder repository itself. It does need `Contents: read/write` on private `Arctic403/RiftLLM` because the worker stores the development-only signing keystore and its expected certificate fingerprint as private release assets under `riftllm-dev-signing-v1`. No signing key material is committed to either repository.

## Dispatch

The workflow is `workflow_dispatch` only. Inputs:

- `source_ref` — exact RiftLLM branch/tag/SHA; normally `main` or a specific commit SHA.
- `client_id` — optional local correlation string.
- `publish` — when true, success/failure outputs are returned to private RiftLLM prereleases.

Pushing RiftLLM source does **not** automatically spend builder minutes or publish an APK. Dispatch remains intentional/manual.
