#!/bin/bash

# Regenerates devices.zip from Garmin's current Connect IQ device catalog.
#
# Unlike the SDK (downloader.sh, sdks.json), the device catalog is not public.
# It is served by the same private API the official SDK Manager and its
# open-source reimplementations use:
#
#   GET https://api.gcs.garmin.com/ciq-product-onboarding/devices?sdkManagerVersion=1.0.5
#   GET https://api.gcs.garmin.com/ciq-product-onboarding/devices/{partNumber}/ciqInfo
#
# Both require an "Authorization: Bearer <token>" header. The token is obtained
# by completing the Garmin SSO login (username/password, plus MFA if enabled
# on the account) - there is no anonymous or service-account access. This
# script deliberately does not perform that login itself: obtain a token with
# your own credentials (for example via `connect-iq-sdk-manager login`, see
# https://github.com/lindell/connect-iq-sdk-manager-cli) and pass it in via
# CIQ_BEARER_TOKEN. The token is short-lived (roughly 1-2 hours).
#
# Devices are packed into multiple devices-N.zip archives (rather than one
# devices.zip) because the full catalog now exceeds GitHub's 100MB per-file
# limit. The Dockerfile unzips every devices-*.zip it finds.
#
# Usage: CIQ_BEARER_TOKEN=... ./refresh-devices.sh [output-prefix]

set -euo pipefail

OUTPUT_PREFIX="${1:-devices}"
MAX_SHARD_BYTES=$((90 * 1024 * 1024))

if [[ -z "${CIQ_BEARER_TOKEN:-}" ]]; then
	echo "Usage: CIQ_BEARER_TOKEN=<token> $0 [output-zip-path]" >&2
	echo "CIQ_BEARER_TOKEN must be a bearer token for api.gcs.garmin.com, obtained by logging in to a Garmin account with Connect IQ developer access." >&2
	exit 1
fi

DEVICES_API="https://api.gcs.garmin.com/ciq-product-onboarding/devices?sdkManagerVersion=1.0.5"
DEVICE_INFO_API="https://api.gcs.garmin.com/ciq-product-onboarding/devices"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Fetching device catalog..."
curl -s -H "Authorization: Bearer ${CIQ_BEARER_TOKEN}" "${DEVICES_API}" -o "${WORK_DIR}/devices.json"

# The API can return multiple entries for the same device name. Keep only
# entries with a downloadable ciqInfo file, and among duplicates keep the one
# with the most recent lastUpdateTime (mirrors the de-duplication logic used
# by connect-iq-sdk-manager-cli).
jq -c '
	map(select(.ciqInfoFileExists == true))
	| group_by(.name)
	| map(max_by(.lastUpdateTime))
	| .[]
	| {name, partNumber}
' "${WORK_DIR}/devices.json" > "${WORK_DIR}/devices.jsonl"

TOTAL=$(wc -l < "${WORK_DIR}/devices.jsonl" | tr -d ' ')
echo "Found ${TOTAL} devices"

mkdir -p "${WORK_DIR}/devices"
COUNT=0
while IFS= read -r device; do
	name=$(echo "${device}" | jq -r '.name')
	part_number=$(echo "${device}" | jq -r '.partNumber')
	COUNT=$((COUNT + 1))
	echo "[${COUNT}/${TOTAL}] Downloading ${name} (${part_number})..."

	device_zip="${WORK_DIR}/${name}.zip"
	# partNumber contains slashes/spaces in some cases, so URL-encode it.
	encoded_part_number=$(jq -rn --arg pn "${part_number}" '$pn|@uri')
	if ! curl -sf -H "Authorization: Bearer ${CIQ_BEARER_TOKEN}" \
		"${DEVICE_INFO_API}/${encoded_part_number}/ciqInfo" -o "${device_zip}"; then
		echo "  warning: failed to download ${name}, skipping" >&2
		continue
	fi

	mkdir -p "${WORK_DIR}/devices/${name}"
	unzip -qo "${device_zip}" -d "${WORK_DIR}/devices/${name}"
	rm -f "${device_zip}"
done < "${WORK_DIR}/devices.jsonl"

case "${OUTPUT_PREFIX}" in
	/*) ABS_OUTPUT_PREFIX="${OUTPUT_PREFIX}" ;;
	*) ABS_OUTPUT_PREFIX="$(pwd)/${OUTPUT_PREFIX}" ;;
esac

# Bin-pack device directories into shards, each targeting roughly
# MAX_SHARD_BYTES of *uncompressed* content. Device assets (PNG/SVG) don't
# compress much further, so an uncompressed-size budget keeps each shard's
# zipped output comfortably under GitHub's 100MB limit; the size check below
# catches it if a shard still comes out too large.
rm -f "${ABS_OUTPUT_PREFIX}"-*.zip
shard=1
shard_bytes=0
shard_has_content=false
for device_dir in "${WORK_DIR}/devices"/*/; do
	device_bytes=$(du -sk "${device_dir}" | cut -f1)
	device_bytes=$((device_bytes * 1024))
	if [[ "${shard_has_content}" == true && $((shard_bytes + device_bytes)) -gt ${MAX_SHARD_BYTES} ]]; then
		shard=$((shard + 1))
		shard_bytes=0
		shard_has_content=false
	fi
	(cd "${WORK_DIR}/devices" && zip -rq -X "${ABS_OUTPUT_PREFIX}-${shard}.zip" "$(basename "${device_dir}")")
	shard_bytes=$((shard_bytes + device_bytes))
	shard_has_content=true
done

echo "Packed into ${shard} shard(s):"
for f in "${ABS_OUTPUT_PREFIX}"-*.zip; do
	size=$(stat -f%z "${f}" 2>/dev/null || stat -c%s "${f}")
	echo "  ${f}: $((size / 1024 / 1024))MB"
	if [[ ${size} -gt 100000000 ]]; then
		echo "  warning: ${f} exceeds GitHub's 100MB file limit, lower MAX_SHARD_BYTES and re-run" >&2
	fi
done
