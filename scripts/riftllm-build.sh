#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${1:?usage: riftllm-build.sh <source-dir>}"
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
LOG_DIR="${RUNNER_TEMP:?}/riftllm-private-logs"
OUT_DIR="${RUNNER_TEMP:?}/riftllm-output"
VERIFY_DIR="${RUNNER_TEMP:?}/riftllm-verification"
SOURCE_CONTRACT_LOG="$LOG_DIR/source-contract.log"
SOURCE_ID="${SOURCE_SHA:-unknown000}"
SHORT_SOURCE="${SOURCE_ID:0:8}"
mkdir -p "$LOG_DIR" "$OUT_DIR" "$VERIFY_DIR"
: > "$SOURCE_CONTRACT_LOG"

source_contract_fail() {
  local message="$1"
  printf '%s\n' "$message" | tee -a "$SOURCE_CONTRACT_LOG" >&2
  {
    printf 'verification_stage=builder-source-contract\n'
    printf '%s\n' "$message"
  } > "$LOG_DIR/failure-summary.txt"
  exit 1
}

bash -n "$SCRIPT_DIR/verify-riftllm-apk.sh"

cd "$SOURCE_DIR"
echo 'Validating exact private RiftLLM source checkout.'
if [ -n "${SOURCE_SHA:-}" ]; then
  ACTUAL_SHA="$(git rev-parse HEAD)"
  test "$ACTUAL_SHA" = "$SOURCE_SHA" || {
    echo 'Private source SHA mismatch; refusing build.' >&2
    exit 1
  }
fi

{
  echo "head=$(git rev-parse HEAD)"
  echo 'status:'
  git status --porcelain=v1 --untracked-files=all
} > "$LOG_DIR/source-integrity.log"
if ! git diff --quiet HEAD -- || [ -n "$(git status --porcelain=v1 --untracked-files=all)" ]; then
  echo 'Private RiftLLM source tree drifted after checkout; refusing build.' >&2
  exit 1
fi

# RiftLLM private source is source-only. Any workflow in the private repo means the privacy
# boundary drifted back toward consuming private-repository Actions minutes.
if [ -d .github/workflows ] && find .github/workflows -type f -print -quit | grep -q .; then
  echo 'Private RiftLLM source contains a GitHub Actions workflow; build boundary violated.' >&2
  exit 1
fi


# Builder-owned source contract for the production-training/RiftPack qualification surface.
# The private source still owns the detailed prebuild gate; these checks keep the public
# builder from silently accepting a stale source shape that no longer contains the required
# Android/native qualification authorities.
for required_source in \
  android/app/src/main/cpp/rift_pack_qualification_lab.cpp \
  android/app/src/main/cpp/rift_pack_qualification_lab.hpp \
  android/app/src/main/cpp/rift_pack_v1.cpp \
  android/app/src/main/cpp/rift_pack_v1.hpp \
  android/app/src/main/cpp/rift_sha256_v1.cpp \
  android/app/src/main/cpp/rift_sha256_v1.hpp \
  android/app/src/main/java/com/riftllm/app/RiftPackQualificationBridge.kt \
  android/app/src/main/java/com/riftllm/app/RiftTrainingDevBridge.kt \
  android/app/src/main/java/com/riftllm/app/RiftTrainDataV2Reader.kt \
  docs/RIFTPACK_QUALIFICATION_LAB_V1.md \
  docs/RIFTPACK_BASELINE_A.md \
  docs/RIFTPACK_V1.md \
  evidence/device/riftpack-qualification-live-2026-09-27.json \
  docs/RIFT_TRAIN_DATA_V2.md \
  tests/rift_pack_v1.cpp; do
  test -f "$required_source" || source_contract_fail \
    "RiftLLM builder contract missing required source: $required_source"
done

require_source_marker() {
  local file="$1"
  local marker="$2"
  local label="$3"
  grep -Fq "$marker" "$file" || source_contract_fail \
    "RiftLLM builder contract missing $label in $file"
}

require_source_marker CMakeLists.txt 'rift_pack_qualification_lab.cpp' 'host RiftPack qualification compile wiring'
require_source_marker android/app/src/main/cpp/CMakeLists.txt 'rift_pack_qualification_lab.cpp' 'Android RiftPack qualification compile wiring'
require_source_marker android/app/src/main/cpp/native_bridge.cpp 'Java_com_riftllm_app_RiftPackQualificationNative_run' 'RiftPack qualification JNI entry'
require_source_marker android/app/src/main/cpp/native_bridge.cpp 'rift_pack_qualification = 16' 'RiftPack native lab-state isolation'
require_source_marker android/app/src/main/java/com/riftllm/app/RiftDevLabProvider.kt 'riftpack_qualification_start' 'RiftPack Dev API start route'
require_source_marker android/app/src/main/java/com/riftllm/app/RiftDevLabProvider.kt 'riftpack_qualification_status' 'RiftPack Dev API status route'
require_source_marker android/app/src/main/cpp/rift_pack_qualification_lab.cpp '\"riftPackFrozen\":false' 'fail-closed RiftPack promotion flag'
require_source_marker android/app/src/main/cpp/rift_pack_qualification_lab.cpp '\"productionPretrainingEligible\":false' 'fail-closed production-pretraining flag'
require_source_marker android/app/src/main/cpp/rift_pack_qualification_lab.cpp 'headerCorruptionRejected' 'header-corruption evidence'
require_source_marker android/app/src/main/cpp/rift_pack_qualification_lab.cpp 'modelSectionCorruptionRejected' 'model-section corruption evidence'
require_source_marker android/app/src/main/cpp/rift_pack_qualification_lab.cpp 'interruptedStagePreserved' 'interrupted-stage preservation evidence'
require_source_marker android/app/src/main/java/com/riftllm/app/RiftPackQualificationBridge.kt 'installedApkSha256' 'installed-APK evidence binding'
require_source_marker android/app/src/main/java/com/riftllm/app/RiftPackQualificationBridge.kt 'MIN_FREE_BYTES = 3L * 1024L * 1024L * 1024L' 'RiftPack real-state qualification storage guard'
require_source_marker android/app/src/main/java/com/riftllm/app/RiftPackQualificationBridge.kt 'architectureSequence()' 'validated trainer-sequence derivation'
require_source_marker android/app/src/main/java/com/riftllm/app/RiftPackQualificationBridge.kt 'actualSelectedTrainerStatePackaged' 'selected-trainer bridge evidence enforcement'
require_source_marker android/app/src/main/java/com/riftllm/app/RiftPackQualificationBridge.kt 'RIFT_PACK_FROZEN = true' 'RiftPack frozen-state source marker'
require_source_marker android/app/src/main/java/com/riftllm/app/RiftPackQualificationBridge.kt 'RIFT_PACK_BASELINE_ID = "riftpack-v1-baseline-a"' 'RiftPack baseline source identity'
require_source_marker android/app/src/main/java/com/riftllm/app/RiftPackQualificationBridge.kt 'riftPackBaselineId' 'RiftPack baseline status field'
require_source_marker android/app/src/main/java/com/riftllm/app/RiftProcessDeathRecoveryBridge.kt 'RIFT_PACK_FROZEN = true' 'process-death current RiftPack frozen-state marker'
require_source_marker docs/RIFTPACK_BASELINE_A.md 'deviceEvidenceSha256=0c7d16740b6d1fc1a95bc893b442e30e8604f37bae8f60e560f93569797c05e3' 'RiftPack frozen evidence identity'
require_source_marker docs/RIFTPACK_BASELINE_A.md 'run-riftpack-qualification-1790557274990.json' 'RiftPack promotion record identity'
require_source_marker docs/RIFTPACK_BASELINE_A.md 'riftPackFrozen=true' 'RiftPack Baseline A freeze marker'
require_source_marker evidence/device/riftpack-qualification-live-2026-09-27.json '"actualSelectedTrainerStatePackaged": true' 'preserved selected-trainer promotion evidence'
require_source_marker evidence/device/riftpack-qualification-live-2026-09-27.json 'f463512c3e04ee4f0d82ec329ee13e72227d922bebcdf63f09a9f27b8c1afd9e' 'preserved complete RiftPack identity'
require_source_marker android/app/src/main/cpp/rift_pack_qualification_lab.cpp 'prepare_rift_micro_process_death_recovery_lab_v1' 'frozen selected-trainer checkpoint authority reuse'
require_source_marker android/app/src/main/cpp/rift_pack_qualification_lab.cpp 'selected-adafactor-checkpoint-v1' 'selected Adafactor checkpoint evidence identity'
require_source_marker android/app/src/main/cpp/rift_pack_qualification_lab.cpp 'selectedCheckpointMasterHash64' 'selected checkpoint master identity evidence'
require_source_marker android/app/src/main/cpp/rift_pack_qualification_lab.cpp 'selectedCheckpointOptimizerHash64' 'selected checkpoint optimizer identity evidence'
require_source_marker android/app/src/main/cpp/rift_pack_qualification_lab.cpp '8622bbf5824dd50b' 'frozen selected checkpoint master hash'
require_source_marker android/app/src/main/cpp/rift_pack_qualification_lab.cpp 'cf1010db7b11a48d' 'frozen selected checkpoint optimizer hash'
require_source_marker android/app/src/main/cpp/rift_pack_qualification_lab.cpp 'trainingDataPackSha256' 'real RiftTrain pack provenance evidence'
printf '%s\n' 'builder-source-contract=pass' >> "$SOURCE_CONTRACT_LOG"

# The source intentionally does not carry generated Gradle-wrapper binaries. Generate the
# pinned wrapper inside this ephemeral checkout, then let the source-owned prebuild gate verify it.
if ! gradle -p android wrapper --gradle-version 8.13 --distribution-type bin \
    > "$LOG_DIR/gradle-wrapper.log" 2>&1; then
  echo 'Pinned Gradle wrapper generation failed; details returned privately.' >&2
  exit 1
fi
chmod +x android/gradlew scripts/prebuild-check.sh scripts/build-android.sh scripts/fetch-llama.sh

if ! ./scripts/prebuild-check.sh > "$LOG_DIR/prebuild.log" 2>&1; then
  echo 'RiftLLM source hardening gate failed; details returned privately.' >&2
  exit 1
fi


command -v cmake >/dev/null 2>&1 || { echo 'cmake is required for RiftLLM host qualification.' >&2; exit 1; }
command -v ctest >/dev/null 2>&1 || { echo 'ctest is required for RiftLLM host qualification.' >&2; exit 1; }
HOST_CMAKE_VERSION="$(cmake --version | awk 'NR == 1 { print $3 }')"
export HOST_CMAKE_VERSION

HOST_BUILD_DIR="${RUNNER_TEMP:?}/riftllm-host-build"
rm -rf "$HOST_BUILD_DIR"
if ! cmake -S . -B "$HOST_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DRIFTLLM_BUILD_TESTS=ON \
    > "$LOG_DIR/host-cmake-configure.log" 2>&1; then
  echo 'RiftLLM host CMake configure failed; details returned privately.' >&2
  exit 1
fi
if ! cmake --build "$HOST_BUILD_DIR" --parallel 2 \
    > "$LOG_DIR/host-cmake-build.log" 2>&1; then
  echo 'RiftLLM host native build failed; details returned privately.' >&2
  exit 1
fi
if ! ctest --test-dir "$HOST_BUILD_DIR" --output-on-failure \
    > "$LOG_DIR/host-ctest.log" 2>&1; then
  {
    printf 'verification_stage=host-ctest\n'
    printf '%s\n' '--- ctest output ---'
    tail -n 120 "$LOG_DIR/host-ctest.log" 2>/dev/null || true
  } > "$LOG_DIR/failure-summary.txt"
  echo 'RiftLLM host native tests failed; details returned privately.' >&2
  exit 1
fi

if ! ./scripts/fetch-llama.sh > "$LOG_DIR/dependency-fetch.log" 2>&1; then
  echo 'Pinned llama.cpp dependency fetch failed; details returned privately.' >&2
  exit 1
fi

if ! ./android/gradlew -p android --no-daemon --stacktrace --build-cache \
    -Pandroid.injected.signing.store.file="$HOME/.android/debug.keystore" \
    -Pandroid.injected.signing.store.password=android \
    -Pandroid.injected.signing.key.alias=androiddebugkey \
    -Pandroid.injected.signing.key.password=android \
    -Pandroid.injected.signing.store.type=JKS \
    :app:assembleDebug \
    > "$LOG_DIR/android-build.log" 2>&1; then
  echo 'RiftLLM Android build failed; details returned privately.' >&2
  exit 1
fi

APK_DIR="$SOURCE_DIR/android/app/build/outputs/apk/debug"
test -d "$APK_DIR" || { echo 'Gradle did not produce the debug APK directory.' >&2; exit 1; }
mapfile -t APKS < <(find "$APK_DIR" -maxdepth 1 -type f -name '*.apk' -print | sort)
test "${#APKS[@]}" -eq 3 || {
  echo "Expected exactly three RiftLLM debug APKs, got ${#APKS[@]}." >&2
  exit 1
}

EXPECTED_SIGNING_SHA256="${RIFTLLM_EXPECTED_SIGNING_SHA256:-}"
if ! [[ "$EXPECTED_SIGNING_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  {
    printf 'verification_stage=stable-signing\n'
    printf 'reason=expected-fingerprint-missing-or-invalid\n'
  } > "$LOG_DIR/failure-summary.txt"
  echo 'RIFTLLM_EXPECTED_SIGNING_SHA256 is missing or invalid.' >&2
  exit 1
fi

APKSIGNER="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}/build-tools/36.0.0/apksigner"
if [ ! -x "$APKSIGNER" ]; then
  {
    printf 'verification_stage=stable-signing\n'
    printf 'reason=apksigner-unavailable\n'
    printf 'resolved_path=%s\n' "$APKSIGNER"
  } > "$LOG_DIR/failure-summary.txt"
  echo 'Android apksigner 36.0.0 is unavailable.' >&2
  exit 1
fi

for apk in "${APKS[@]}"; do
  SIGNING_LOG="$VERIFY_DIR/signing-$(basename "$apk").txt"
  if ! "$APKSIGNER" verify --print-certs "$apk" > "$SIGNING_LOG" 2>&1; then
    cp "$SIGNING_LOG" "$LOG_DIR/signing-$(basename "$apk").log" || true
    {
      printf 'verification_stage=stable-signing\n'
      printf 'reason=apksigner-verification-failed\n'
      printf 'artifact=%s\n' "$(basename "$apk")"
      printf '%s\n' '--- apksigner output ---'
      tail -n 40 "$SIGNING_LOG" 2>/dev/null || true
    } > "$LOG_DIR/failure-summary.txt"
    echo "APK signature verification failed for $(basename "$apk")." >&2
    exit 1
  fi

  ACTUAL_SIGNING_SHA256="$(sed -n -E 's/^.*certificate SHA-256 digest:[[:space:]]*([0-9A-Fa-f:]+).*$/\1/p' "$SIGNING_LOG" | head -n 1 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
  if ! [[ "$ACTUAL_SIGNING_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    cp "$SIGNING_LOG" "$LOG_DIR/signing-$(basename "$apk").log" || true
    {
      printf 'verification_stage=stable-signing\n'
      printf 'reason=certificate-fingerprint-unparseable\n'
      printf 'artifact=%s\n' "$(basename "$apk")"
      printf 'expected_sha256=%s\n' "$EXPECTED_SIGNING_SHA256"
      printf '%s\n' '--- apksigner output ---'
      tail -n 40 "$SIGNING_LOG" 2>/dev/null || true
    } > "$LOG_DIR/failure-summary.txt"
    echo "Could not parse APK signing certificate for $(basename "$apk")." >&2
    exit 1
  fi

  if [ "$ACTUAL_SIGNING_SHA256" != "$EXPECTED_SIGNING_SHA256" ]; then
    {
      printf 'verification_stage=stable-signing\n'
      printf 'reason=certificate-fingerprint-mismatch\n'
      printf 'artifact=%s\n' "$(basename "$apk")"
      printf 'expected_sha256=%s\n' "$EXPECTED_SIGNING_SHA256"
      printf 'actual_sha256=%s\n' "$ACTUAL_SIGNING_SHA256"
    } > "$LOG_DIR/failure-summary.txt"
    echo "APK signing certificate mismatch for $(basename "$apk")." >&2
    exit 1
  fi
done

seen_arm32=0
seen_arm64=0
seen_universal=0
for apk in "${APKS[@]}"; do
  entries="$(unzip -Z1 "$apk")"
  has32=0
  has64=0
  grep -Fxq 'lib/armeabi-v7a/libriftllm.so' <<< "$entries" && has32=1
  grep -Fxq 'lib/arm64-v8a/libriftllm.so' <<< "$entries" && has64=1
  if [ "$has32" -eq 1 ] && [ "$has64" -eq 1 ]; then
    kind=universal
    dest="$OUT_DIR/RiftLLM-universal-debug.apk"
    seen_universal=$((seen_universal + 1))
  elif [ "$has32" -eq 1 ]; then
    kind=armeabi-v7a
    dest="$OUT_DIR/RiftLLM-armeabi-v7a-debug.apk"
    seen_arm32=$((seen_arm32 + 1))
  elif [ "$has64" -eq 1 ]; then
    kind=arm64-v8a
    dest="$OUT_DIR/RiftLLM-arm64-v8a-debug.apk"
    seen_arm64=$((seen_arm64 + 1))
  else
    echo 'APK does not contain a recognized RiftLLM native ABI payload.' >&2
    exit 1
  fi
  cp "$apk" "$dest"
  if ! bash "$SCRIPT_DIR/verify-riftllm-apk.sh" "$dest" "$kind" \
      > "$VERIFY_DIR/${kind}.log" 2>&1; then
    cp "$VERIFY_DIR/${kind}.log" "$LOG_DIR/apk-${kind}-verification.log" || true
    {
      printf 'verification_stage=apk\n'
      printf 'abi=%s\n' "$kind"
      printf 'artifact=%s\n' "$(basename "$dest")"
      printf '%s\n' '--- verifier output ---'
      tail -n 80 "$VERIFY_DIR/${kind}.log" 2>/dev/null || true
    } > "$LOG_DIR/failure-summary.txt"
    echo "RiftLLM ${kind} APK verification failed; details returned privately." >&2
    exit 1
  fi
done

test "$seen_arm32" -eq 1 && test "$seen_arm64" -eq 1 && test "$seen_universal" -eq 1 || {
  echo 'RiftLLM APK ABI set was incomplete or duplicated.' >&2
  exit 1
}

cd "$OUT_DIR"
sha256sum RiftLLM-*.apk > sha256sums.txt

cat > provenance.txt <<EOF
format=riftllm-private-build-provenance-v1
source_repo=Arctic403/RiftLLM
source_sha=${SOURCE_ID}
builder_repo=${GITHUB_REPOSITORY:-unknown}
builder_sha=${GITHUB_SHA:-unknown}
builder_run_id=${GITHUB_RUN_ID:-unknown}
build_type=debug
gradle=8.13
android_platform=36
android_build_tools=36.0.0
ndk=28.2.13676358
host_cmake=${HOST_CMAKE_VERSION}
host_ctest=passed
EOF

python3 - "$OUT_DIR" <<'PY'
import hashlib
import json
import os
import sys

out = sys.argv[1]
artifacts = []
for name in sorted(n for n in os.listdir(out) if n.endswith('.apk')):
    path = os.path.join(out, name)
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    artifacts.append({"name": name, "bytes": os.path.getsize(path), "sha256": h.hexdigest()})
manifest = {
    "format": "riftllm-private-build-v1",
    "sourceRepo": "Arctic403/RiftLLM",
    "sourceSha": os.environ.get("SOURCE_SHA", "unknown"),
    "builderRepo": os.environ.get("GITHUB_REPOSITORY", "unknown"),
    "builderSha": os.environ.get("GITHUB_SHA", "unknown"),
    "builderRunId": os.environ.get("GITHUB_RUN_ID", "unknown"),
    "buildType": "debug",
    "gradle": "8.13",
    "androidPlatform": 36,
    "buildTools": "36.0.0",
    "ndk": "28.2.13676358",
    "hostCmake": os.environ.get("HOST_CMAKE_VERSION", "unknown"),
    "hostCtest": "passed",
    "artifacts": artifacts,
}
with open(os.path.join(out, 'build-manifest.json'), 'w', encoding='utf-8') as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write('\n')
PY

cp build-manifest.json provenance.txt sha256sums.txt "$VERIFY_DIR/"
(cd "$VERIFY_DIR" && zip -qr "$OUT_DIR/RiftLLM-verification-${SHORT_SOURCE}.zip" .)

echo 'RiftLLM private source built and verified; outputs prepared only for private prerelease publication.'
