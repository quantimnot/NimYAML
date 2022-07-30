#!/bin/sh

set -Cue

error() {
  echo "Error: $@"
  exit 1
}

# Params
bind_address=$1
extensions=$2
workspace=$3

# Validate inputs
expected_arg_count=3
test $# -eq $expected_arg_count ||
  error "Incorrect number of arguments ($#/$expected_arg_count)."

export SERVICE_URL=https://open-vsx.org/vscode/gallery
export ITEM_URL=https://open-vsx.org/vscode/item
export CODE_SERVER_CONFIG=~/.config/code-server/config.yaml

# Create config
mkdir -p ~/.config/code-server
cat > ~/.config/code-server/config.yaml <<EOF
---
bind-addr: $bind_address
auth: none
cert: false
disable-telemetry: true
disable-update-check: true
EOF

code-server --help

# Install extensions
while read ext
do code-server --install-extension "$ext"
done << EOF
$extensions
EOF

# Start the server
code-server "$workspace" &

echo "::set-output name=bind-address::$bind_address"
