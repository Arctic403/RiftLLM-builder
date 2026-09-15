#!/usr/bin/env bash
set -euo pipefail

APK="${1:?usage: verify-riftllm-apk.sh <apk> <armeabi-v7a|arm64-v8a|universal>}"
EXPECTED="${2:?expected ABI kind is required}"
test -f "$APK" || { echo "APK not found: $APK" >&2; exit 1; }
case "$EXPECTED" in armeabi-v7a|arm64-v8a|universal) ;; *) echo "Invalid ABI expectation: $EXPECTED" >&2; exit 1 ;; esac

BUILD_TOOLS="${ANDROID_HOME:?}/build-tools/36.0.0"
AAPT2="$BUILD_TOOLS/aapt2"
ZIPALIGN="$BUILD_TOOLS/zipalign"
APKSIGNER="$BUILD_TOOLS/apksigner"
APKANALYZER="$(command -v apkanalyzer || true)"
if [ -z "$APKANALYZER" ] && [ -x "$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer" ]; then
  APKANALYZER="$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer"
fi
for tool in "$AAPT2" "$ZIPALIGN" "$APKSIGNER"; do
  test -x "$tool" || { echo "Required Android build tool missing: $tool" >&2; exit 1; }
done
test -x "$APKANALYZER" || { echo 'Required Android SDK tool apkanalyzer is missing.' >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo 'unzip is required.' >&2; exit 1; }

entries="$(unzip -Z1 "$APK")"
require_entry() {
  grep -Fxq "$1" <<< "$entries" || { echo "Missing APK entry: $1" >&2; exit 1; }
}
require_entry AndroidManifest.xml
require_entry classes.dex
require_entry resources.arsc

badging="$($AAPT2 dump badging "$APK")"
grep -Fq "package: name='com.riftllm.app'" <<< "$badging" || {
  echo 'APK package id is not com.riftllm.app.' >&2
  exit 1
}

permissions="$($AAPT2 dump permissions "$APK")"
if grep -Fq 'android.permission.INTERNET' <<< "$permissions"; then
  echo 'RiftLLM APK unexpectedly requests INTERNET permission.' >&2
  exit 1
fi

has32=0
has64=0
grep -Fxq 'lib/armeabi-v7a/libriftllm.so' <<< "$entries" && has32=1
grep -Fxq 'lib/arm64-v8a/libriftllm.so' <<< "$entries" && has64=1
case "$EXPECTED" in
  armeabi-v7a) test "$has32" -eq 1 && test "$has64" -eq 0 ;;
  arm64-v8a) test "$has32" -eq 0 && test "$has64" -eq 1 ;;
  universal) test "$has32" -eq 1 && test "$has64" -eq 1 ;;
esac || { echo "APK native ABI payload does not match $EXPECTED." >&2; exit 1; }

# AGP/NDK 28 builds must preserve 16 KiB-page-compatible alignment for packaged native libs.
"$ZIPALIGN" -c -P 16 -v 4 "$APK" >/dev/null
"$APKSIGNER" verify --verbose --print-certs "$APK" >/dev/null

# Prove the final artifact contains the RiftLLM Android shell without assuming D8/R8
# placed MainActivity in classes.dex. apkanalyzer understands the DEX format and scans all
# packaged DEX files by default, so this remains valid when multidex layout changes.
manifest_xml="$($APKANALYZER manifest print "$APK")"
grep -Fq 'com.riftllm.app.MainActivity' <<< "$manifest_xml" || {
  echo 'RiftLLM MainActivity is missing from the merged APK manifest.' >&2
  exit 1
}

dex_packages="$($APKANALYZER dex packages --defined-only "$APK")"
grep -Fq 'com.riftllm.app.MainActivity' <<< "$dex_packages" || {
  echo 'RiftLLM MainActivity is not defined in any packaged DEX file.' >&2
  exit 1
}

check_native_marker() {
  local entry="$1"
  local tmp
  tmp="$(mktemp)"
  unzip -p "$APK" "$entry" > "$tmp"
  if ! grep -aFq 'neon16-lane-split-b64' "$tmp"; then
    rm -f "$tmp"
    echo "Promoted RiftTensor marker missing from $entry." >&2
    exit 1
  fi
  rm -f "$tmp"
}
[ "$has32" -eq 1 ] && check_native_marker 'lib/armeabi-v7a/libriftllm.so'
[ "$has64" -eq 1 ] && check_native_marker 'lib/arm64-v8a/libriftllm.so'

printf 'RiftLLM APK verified: %s (%s)\n' "$(basename "$APK")" "$EXPECTED"
