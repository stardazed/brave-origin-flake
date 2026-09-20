#!/usr/bin/env bash
set -euo pipefail

ReportError() {
    local exitCode=$?
    local failedCommand=$1
    local lineNumber=$2

    printf 'Update failed at line %s while running: %s (exit code %s)\n' \
        "$lineNumber" "$failedCommand" "$exitCode" >&2
    exit "$exitCode"
}

trap 'ReportError "$BASH_COMMAND" "$LINENO"' ERR

# URL of the APT repository packages file
PACKAGES_URL="https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages"

# Fetch the Packages file.  A silent HTTP error used to be treated as an empty
# package index, which hid the actual reason the scheduled update failed.
if ! PACKAGES=$(curl --fail --location --retry 3 --silent --show-error "$PACKAGES_URL"); then
    echo "Could not download the Brave APT package index: $PACKAGES_URL" >&2
    exit 1
fi

# Extract the version and filename for brave-origin
# We look for the brave-origin package block
BLOCK=$(awk -v RS= '$1 == "Package:" && $2 == "brave-origin" { print; exit }' <<< "$PACKAGES")

if [ -z "$BLOCK" ]; then
    echo "Could not find brave-origin in APT repository."
    exit 1
fi

VERSION=$(echo "$BLOCK" | awk '/^Version:/{print $2}')
FILENAME=$(echo "$BLOCK" | awk '/^Filename:/{print $2}')

if [ -z "$VERSION" ] || [ -z "$FILENAME" ]; then
    echo "Could not parse version or filename."
    exit 1
fi

DEB_URL="https://brave-browser-apt-release.s3.brave.com/$FILENAME"

echo "Latest brave-origin version is $VERSION"

# Read the current version from versions.json if it exists
if [ -f versions.json ]; then
    CURRENT_VERSION=$(jq -r '."brave-origin".version // empty' versions.json)
    if [ "$CURRENT_VERSION" == "$VERSION" ]; then
        echo "Already up to date."
        exit 0
    fi
fi

echo "Fetching new version and generating hash..."
# We use nix store prefetch-file to get the SRI hash
if ! PREFETCH_RESULT=$(nix store prefetch-file --json "$DEB_URL"); then
    echo "Could not prefetch the Brave package: $DEB_URL" >&2
    exit 1
fi

if ! HASH=$(printf '%s\n' "$PREFETCH_RESULT" | jq --exit-status --raw-output '.hash'); then
    echo "Could not read the hash from Nix's prefetch result." >&2
    exit 1
fi

if [ -z "$HASH" ] || [ "$HASH" = "null" ]; then
    echo "Could not generate a hash for $DEB_URL."
    exit 1
fi

# Update versions.json
cat <<EOF > versions.json
{
  "brave-origin": {
    "version": "$VERSION",
    "url": "$DEB_URL",
    "hash": "$HASH"
  }
}
EOF

echo "Updated versions.json with version $VERSION"
