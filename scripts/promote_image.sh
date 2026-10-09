#!/usr/bin/env bash
set -Eeuo pipefail
: "${SOURCE_REF:?}" "${SOURCE_IMAGE:?}" "${SOURCE_TAG:?}" "${GHCR_TOKEN:?}"
: "${GITHUB_ACTOR:?}" "${GITHUB_OUTPUT:?}" "${RUNNER_TEMP:?}"
mkdir -p reports/promotion
if [[ ! "$SOURCE_REF" =~ ^ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$ ]]; then
  echo 'Invalid immutable source reference' >&2
  exit 1
fi
if [[ ! "$SOURCE_TAG" =~ ^sha-[a-f0-9]{12}-run-[0-9]+-[0-9]+$ ]]; then
  echo 'Invalid source tag' >&2
  exit 1
fi
if [[ "${SOURCE_REF%@*}" != "$SOURCE_IMAGE" ]]; then
  echo 'Source repository mismatch' >&2
  exit 1
fi
expected="${SOURCE_REF##*@}"
staging_image="${SOURCE_IMAGE}-staging"
staging_tag="${staging_image}:${SOURCE_TAG}"
authfile="$(mktemp "$RUNNER_TEMP/skopeo-auth.XXXXXX")"

printf '{}\n' > "$authfile"
trap 'rm -f "$authfile"' EXIT
printf '%s' "$GHCR_TOKEN" | skopeo login --authfile "$authfile" \
  --username "$GITHUB_ACTOR" --password-stdin ghcr.io
unset GHCR_TOKEN
skopeo --version > reports/promotion/skopeo-version.txt
skopeo inspect --authfile "$authfile" "docker://${SOURCE_REF}" \
  > reports/promotion/source.json

skopeo inspect --raw --authfile "$authfile" "docker://${SOURCE_IMAGE}:${SOURCE_TAG}" \
  > reports/promotion/source-manifest.json
actual="sha256:$(sha256sum reports/promotion/source-manifest.json | cut -d ' ' -f1)"
[[ "$actual" == "$expected" ]] || { echo 'Source tag no longer matches digest'; exit 1; }
skopeo copy --all --preserve-digests --retry-times 3 --authfile "$authfile" \
  --digestfile reports/promotion/copied.digest \
  "docker://${SOURCE_REF}" "docker://${staging_tag}"
skopeo inspect --authfile "$authfile" "docker://${staging_tag}" \
  > reports/promotion/staging.json
skopeo inspect --raw --authfile "$authfile" "docker://${staging_tag}" \
  > reports/promotion/staging-manifest.json
actual="sha256:$(sha256sum reports/promotion/staging-manifest.json | cut -d ' ' -f1)"
[[ "$actual" == "$expected" ]] || { echo 'Staging digest mismatch'; exit 1; }
[[ "$(tr -d '\r\n' < reports/promotion/copied.digest)" == "$expected" ]] \
  || { echo 'Copy digest mismatch'; exit 1; }

staging_ref="${staging_tag}@${expected}"
printf 'Source: %s\nDestination: %s\nDigest equality: PASS\n' \
  "$SOURCE_REF" "$staging_ref" | tee reports/promotion/promotion.txt
printf 'staging_ref=%s\n' "$staging_ref" >> "$GITHUB_OUTPUT"
