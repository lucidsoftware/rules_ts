#!/usr/bin/env bash
set -o nounset -o errexit -o pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

TOOL_VERSIONS_JQ_FILTER='
[
    .versions[]
    | select(.version | test("^[0-9.]+$"))
    | {key: .version, value: .dist.integrity}
] | from_entries
'

REGISTRY_JSON=$(mktemp)
NATIVE_VERSIONS=$(mktemp)
NEW=$(mktemp)
trap 'rm -f "$REGISTRY_JSON" "$NATIVE_VERSIONS" "$NEW"' EXIT

curl --silent https://registry.npmjs.org/typescript >"$REGISTRY_JSON"

awk '/NATIVE_TYPESCRIPT_VERSIONS =/ { exit } { print }' "$SCRIPT_DIR/versions.bzl" >"$NEW"

RC_VERSION=$(jq -r '."dist-tags".rc // empty' "$REGISTRY_JSON")
if [[ -n "$RC_VERSION" ]]; then
	echo "$RC_VERSION" >>"$NATIVE_VERSIONS"
fi

jq -r '
    .versions[]
    | select(.version | test("^[0-9.]+$"))
    | select(
        ((.optionalDependencies // {})
        | keys
        | map(select(startswith("@typescript/")))
        | length) > 0
    )
    | .version
' "$REGISTRY_JSON" >>"$NATIVE_VERSIONS"

echo "NATIVE_TYPESCRIPT_VERSIONS = {" >>"$NEW"
awk 'NF && !seen[$0]++' "$NATIVE_VERSIONS" | while read -r version; do
	native_packages=$(jq -r --arg version "$version" '
        .versions[]
        | select(.version == $version)
        | (.optionalDependencies // {})
        | to_entries
        | sort_by(.key)[]
        | select(.key | startswith("@typescript/"))
        | [.key, .value]
        | @tsv
    ' "$REGISTRY_JSON")
	if [[ -z "$native_packages" ]]; then
		continue
	fi

	echo "    \"$version\": {" >>"$NEW"
	version_integrity=$(jq -r --arg version "$version" '.versions[] | select(.version == $version) | .dist.integrity' "$REGISTRY_JSON")
	echo "        \"integrity\": \"$version_integrity\"," >>"$NEW"
	echo "        \"native_package_integrities\": {" >>"$NEW"
	while IFS=$'\t' read -r package_name package_version; do
		native_package="${package_name#@typescript/}"
		package_url_name="${package_name/\//%2f}"
		integrity=$(curl --silent "https://registry.npmjs.org/${package_url_name}/${package_version}" | jq -r '.dist.integrity')
		echo "            \"$native_package\": \"$integrity\"," >>"$NEW"
	done <<<"$native_packages"
	echo "        }," >>"$NEW"
	echo "    }," >>"$NEW"
done
echo "}" >>"$NEW"
echo "" >>"$NEW"

echo -n "TOOL_VERSIONS = " >>"$NEW"
jq "$TOOL_VERSIONS_JQ_FILTER" "$REGISTRY_JSON" >>"$NEW"

cp "$NEW" "$SCRIPT_DIR/versions.bzl"

# jq emits 2-space indentation; reformat to the repo's buildifier style so the
# generated file is committable as-is without a separate manual step.
npx @bazel/buildifier "$SCRIPT_DIR/versions.bzl"
