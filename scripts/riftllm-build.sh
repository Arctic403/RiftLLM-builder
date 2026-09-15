#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${1:?usage: riftllm-build.sh <source-dir>}"
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
LOG_DIR="${RUNNER_TEMP:?}/riftllm-private-logs"
OUT_DIR="${RUNNER_TEMP:?}/riftllm-output"
VERIFY_DIR="${RUNNER_TEMP:?}/riftllm-verification"
SOURCE_ID="${SOURCE_SHA:-unknown000}"
SHORT_SOURCE="${SOURCE_ID:0:8}"
mkdir -p "$LOG_DIR" "$OUT_DIR" "$VERIFY_DIR"

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

if ! ./scripts/fetch-llama.sh > "$LOG_DIR/dependency-fetch.log" 2>&1; then
  echo 'Pinned llama.cpp dependency fetch failed; details returned privately.' >&2
  exit 1
fi

if ! ./android/gradlew -p android --no-daemon --stacktrace --build-cache :app:assembleDebug \
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
    "artifacts": artifacts,
}
with open(os.path.join(out, 'build-manifest.json'), 'w', encoding='utf-8') as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write('\n')
PY

cp build-manifest.json provenance.txt sha256sums.txt "$VERIFY_DIR/"
(cd "$VERIFY_DIR" && zip -qr "$OUT_DIR/RiftLLM-verification-${SHORT_SOURCE}.zip" .)

echo 'RiftLLM private source built and verified; outputs prepared only for private prerelease publication.'
