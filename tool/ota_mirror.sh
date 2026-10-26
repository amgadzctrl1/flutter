#!/usr/bin/env bash
#
# Download the pinned Shorebird/Flutter engine artifacts for one host and, with
# --publish, upload them to a GitHub release in this repository.
#
# The resulting zip preserves the URL layout of download.shorebird.dev, so the
# `ota` CLI can serve it from 127.0.0.1 and point FLUTTER_STORAGE_BASE_URL at
# it. Nothing in the bundle comes from anywhere except download.shorebird.dev.
#
# Usage:
#   tool/ota_mirror.sh <darwin-arm64|linux-x64> <output-dir> [--publish]
#
# Environment:
#   SHOREBIRD_ENGINE_REVISION  engine revision (default below)
#   OTA_UPSTREAM_URL           artifact source (default https://download.shorebird.dev)
#   RELEASE_TAG                release tag for --publish
#   GH_TOKEN                   token for --publish (gh CLI)
#
# The script is deliberately boring: explicit lists, no discovery. A missing
# artifact fails the run instead of producing a mirror with a hidden hole.

set -euo pipefail

HOST="${1:?usage: ota_mirror.sh <darwin-arm64|linux-x64> <output-dir> [--publish]}"
OUT="${2:?usage: ota_mirror.sh <darwin-arm64|linux-x64> <output-dir> [--publish]}"
PUBLISH="${3:-}"

ENGINE_REVISION="${SHOREBIRD_ENGINE_REVISION:-4b936a0c03e13389ddfb1ac48823f187964975c2}"
UPSTREAM="${OTA_UPSTREAM_URL:-https://download.shorebird.dev}"
GRADLE_WRAPPER_PATH="${OTA_GRADLE_WRAPPER_PATH:-flutter_infra_release/gradle-wrapper/fd5c1f2c013565a3bea56ada6df9d2b8e96d56aa/gradle-wrapper.tgz}"
MAVEN_VERSION="1.0.0-${ENGINE_REVISION}"
MAVEN_ROOT="download.flutter.io/io/flutter"

case "$HOST" in
  darwin-arm64)
    DART_ZIP="dart-sdk-darwin-arm64.zip"
    HOST_ARTIFACTS="darwin-arm64"
    GEN_SNAPSHOT_HOST="darwin-x64"
    PATCH_ZIP="patch-darwin-arm64.zip"
    IOS=1
    ;;
  linux-x64)
    DART_ZIP="dart-sdk-linux-x64.zip"
    HOST_ARTIFACTS="linux-x64"
    GEN_SNAPSHOT_HOST="linux-x64"
    PATCH_ZIP="patch-linux-x64.zip"
    IOS=0
    ;;
  *)
    echo "unsupported host: $HOST" >&2
    echo "supported: darwin-arm64, linux-x64" >&2
    exit 2
    ;;
esac

ENGINE_ROOT="flutter_infra_release/flutter/${ENGINE_REVISION}"

common_paths=(
  "${ENGINE_ROOT}/sky_engine.zip"
  "${ENGINE_ROOT}/flutter_gpu.zip"
  "${ENGINE_ROOT}/flutter_patched_sdk.zip"
  "${ENGINE_ROOT}/flutter_patched_sdk_product.zip"
  "${ENGINE_ROOT}/${HOST_ARTIFACTS}/artifacts.zip"
  "${ENGINE_ROOT}/${HOST_ARTIFACTS}/font-subset.zip"
  "${GRADLE_WRAPPER_PATH}"
)

host_paths=(
  "${ENGINE_ROOT}/${DART_ZIP}"
  "${ENGINE_ROOT}/android-arm-profile/${GEN_SNAPSHOT_HOST}.zip"
  "${ENGINE_ROOT}/android-arm-release/${GEN_SNAPSHOT_HOST}.zip"
  "${ENGINE_ROOT}/android-arm64-profile/${GEN_SNAPSHOT_HOST}.zip"
  "${ENGINE_ROOT}/android-arm64-release/${GEN_SNAPSHOT_HOST}.zip"
  "${ENGINE_ROOT}/android-x64-profile/${GEN_SNAPSHOT_HOST}.zip"
  "${ENGINE_ROOT}/android-x64-release/${GEN_SNAPSHOT_HOST}.zip"
  "shorebird/${ENGINE_REVISION}/${PATCH_ZIP}"
)

ios_paths=(
  "${ENGINE_ROOT}/ios/artifacts.zip"
  "${ENGINE_ROOT}/ios-profile/artifacts.zip"
  "${ENGINE_ROOT}/ios-release/artifacts.zip"
)

maven_paths=()
for group in flutter_embedding_release armeabi_v7a_release arm64_v8a_release x86_64_release; do
  maven_paths+=(
    "${MAVEN_ROOT}/${group}/${MAVEN_VERSION}/${group}-${MAVEN_VERSION}.pom"
    "${MAVEN_ROOT}/${group}/${MAVEN_VERSION}/${group}-${MAVEN_VERSION}.jar"
  )
done

paths=("${common_paths[@]}" "${host_paths[@]}" "${maven_paths[@]}")
if [[ "$IOS" == "1" ]]; then
  paths+=("${ios_paths[@]}")
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "Mirror host:       $HOST"
echo "Engine revision:   $ENGINE_REVISION"
echo "Upstream:          $UPSTREAM"
echo "Files:             ${#paths[@]}"
echo

total=0
for path in "${paths[@]}"; do
  destination="$OUT/$path"
  mkdir -p "$(dirname "$destination")"
  echo "==> $path"
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 4 \
    --retry-delay 2 \
    --retry-all-errors \
    --continue-at - \
    --output "$destination" \
    "$UPSTREAM/$path"
  if [[ ! -s "$destination" ]]; then
    echo "empty download: $path" >&2
    exit 1
  fi
  size="$(wc -c < "$destination" | tr -d ' ')"
  total=$((total + size))
done

echo
echo "Total bytes: $total"

python3 - "$OUT" "$HOST" "$ENGINE_REVISION" <<'PY'
import datetime
import hashlib
import json
import os
import sys

root, host, revision = sys.argv[1], sys.argv[2], sys.argv[3]
files = []
for directory, _, names in os.walk(root):
    for name in sorted(names):
        if name == 'manifest.json':
            continue
        path = os.path.join(directory, name)
        relative = os.path.relpath(path, root).replace(os.sep, '/')
        digest = hashlib.sha256()
        with open(path, 'rb') as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b''):
                digest.update(chunk)
        files.append({
            'path': relative,
            'bytes': os.path.getsize(path),
            'sha256': digest.hexdigest(),
        })
files.sort(key=lambda entry: entry['path'])
manifest = {
    'format': 1,
    'host': host,
    'engine_revision': revision,
    'generated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'files': files,
}
with open(os.path.join(root, 'manifest.json'), 'w', encoding='utf-8') as handle:
    json.dump(manifest, handle, indent=2)
    handle.write('\n')
print(f"Wrote manifest.json with {len(files)} files")
PY

tag="${RELEASE_TAG:-ota-toolchain-${ENGINE_REVISION:0:8}}"
bundle_name="ota-toolchain-${ENGINE_REVISION:0:8}-${HOST}.zip"
bundle="$(dirname "$OUT")/$bundle_name"
checksums="$(dirname "$OUT")/SHA256SUMS-${HOST}.txt"

rm -f "$bundle"
echo
echo "==> packaging $bundle_name"
(
  cd "$OUT"
  zip -q -0 -r "$bundle" .
)

bundle_sha="$(shasum -a 256 "$bundle" | awk '{print $1}')"
bundle_bytes="$(wc -c < "$bundle" | tr -d ' ')"
printf '%s  %s\n' "$bundle_sha" "$bundle_name" > "$checksums"

{
  echo "### OTA toolchain mirror: $HOST"
  echo
  echo '```'
  cat "$checksums"
  echo "bytes: $bundle_bytes"
  echo "tag:   $tag"
  echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo
echo "Bundle:    $bundle"
echo "Bytes:     $bundle_bytes"
echo "SHA-256:   $bundle_sha"
echo "Checksums: $checksums"

if [[ "$PUBLISH" != "--publish" ]]; then
  echo
  echo "Not publishing (pass --publish to upload)."
  exit 0
fi

: "${GH_TOKEN:?GH_TOKEN is required for --publish}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required for --publish}"

notes="Pinned Shorebird/Flutter engine artifacts for \`${ENGINE_REVISION}\`, packaged for the self-hosted OTA toolchain. The \`ota\` CLI serves these files from 127.0.0.1 so Flutter and Gradle never contact download.shorebird.dev."

if ! gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  gh release create "$tag" \
    --repo "$GITHUB_REPOSITORY" \
    --title "OTA toolchain mirror ${ENGINE_REVISION:0:8}" \
    --notes "$notes" || true
fi

gh release upload "$tag" "$bundle" "$checksums" \
  --repo "$GITHUB_REPOSITORY" \
  --clobber

echo "Published $tag: $bundle_name"
