#!/bin/sh

set -Cue

error() {
  echo "Error: $@"
  exit 1
}

# Params
platform_os="$1"
platform_arch="$2"
eval choosenim_path="$3"
eval nimble_path="$4"
nim_version="$5"

# XXX: Bug workaround
# Otherwise, lots of error messages trying to install to non-existent paths.
mkdir -p "$choosenim_path/bin"
mkdir -p "$nimble_path/bin"

# Validate inputs
expected_arg_count=5
test $# -eq $expected_arg_count ||
  error "Incorrect number of arguments ($#/$expected_arg_count)."

test -n "$GITHUB_TOKEN"

case "$platform_arch" in
  amd64|X64) :;;
  *) error "Unsupported CPU architecture '$platform_arch' for choosenim.";;
esac

{ # Get latest choosenim version
  choosenim_version=$(gh api repos/dom96/choosenim/releases/latest | jq -r '.name')
  echo "$choosenim_version" | grep -Eq 'v\d+\.\d+\.\d+'
  echo "::set-output name=choosenim-version::$choosenim_version"
} || error "Failed to get latest choosenim version."

# Set PATHs
case "$platform_os" in
  [w]indows*)
    echo "$(cygpath -wa "$nimble_path/bin")"
    echo "$(cygpath -wa "$choosenim_path/bin")";;
  *)
    echo "$nimble_path/bin"
    echo "$choosenim_path/bin";;
esac >> "$GITHUB_PATH"

# Disable telemetry
echo "CHOOSENIM_NO_ANALYTICS=1" >> "$GITHUB_ENV"

# Set default nim version to install
echo "CHOOSENIM_CHOOSE_VERSION=$nim_version" >> "$GITHUB_ENV"
