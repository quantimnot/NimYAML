#!/bin/sh

set -Cue

error() {
  echo "Error: $@"
  exit 1
}

# Params
platform_os=$1
platform_arch=$2
eval install_path=$3

# Validate inputs
expected_arg_count=3
test $# -eq $expected_arg_count ||
  error "Incorrect number of arguments ($#/$expected_arg_count)."

# Create required directories if they don't exist
mkdir -p "$install_path"

case $(echo "$platform_os" | tr '[:upper:]' '[:lower:]') in
  windows)
    version=$(yarn info code-server version --json | jq -r '.data')
    PATH="$install_path/node_modules/.bin:$PATH"
    install="yarn --cwd $install_path add code-server"
    ;;
  linux|macos[x]|posix)
    version=$(gh api repos/coder/code-server/releases/latest | jq -r '.name')
    PATH="$install_path/bin:$PATH"
    install="curl -fsSL https://code-server.dev/install.sh | sh -s -- --method standalone --prefix $install_path"
    ;;
  *) error "Unrecognized platform OS '$platform_os'";;
esac

# Set outputs for GitHub runner
cat <<EOF
::set-output name=version::$version
::set-output name=install::$install
EOF

# Set PATHs
echo "PATH=$PATH" >> $GITHUB_ENV
