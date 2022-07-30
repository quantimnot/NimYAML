#!/bin/sh

set -Cue

error() {
  echo "Error: $@"
  exit 1
}

# Params
platform_os=$1
eval nim_workdir_path=$2
eval nimble_path=$3
nim_repository=$4
nim_version=$5
nim_stable_version=$6
nim_devel_version=$7

# Validate inputs
expected_arg_count=7
test $# -eq $expected_arg_count ||
  error "Incorrect number of arguments ($#/$expected_arg_count)."

case $nim_version in
  stable) ref=$nim_stable_version;;
  devel) ref=$nim_devel_version;;
  *) ref=$nim_version;;
esac

sha=$(git ls-remote "$nim_repository" $ref | cut -f1)
echo "$sha" | grep -Eq '[a-z0-9]{40}' || error "Invalid git ref sha '$sha'."
bootstrap='./build_all.sh'
build_nim='bin/nim c -o:bin/nim -d:release compiler/nim'
build_tools='./koch tools'
shell='bash'

case $(echo "$platform_os" | tr '[:upper:]' '[:lower:]') in
  windows*)
    bootstrap='./build_all.bat'
    shell='bash';;
  posix|linux|macos[x]) :;;
  *) error "Unrecognized platform OS '$platform_os'";;
esac

# Set outputs for GitHub runner
cat <<EOF
::set-output name=sha::$sha
::set-output name=version::$ref
::set-output name=bootstrap::$bootstrap
::set-output name=build-nim::$build_nim
::set-output name=build-tools::$build_tools
::set-output name=shell::$shell
EOF

# Set PATHs
PATH="$HOME/.nimble/bin:$PWD/$nim_workdir_path/bin:$PATH"
case "$platform_os" in
  [w]indows*)
    echo "$(cygpath -wa "$nimble_path/bin")"
    echo "$(cygpath -wa "$nim_workdir_path/bin")";;
  *)
    echo "$nimble_path/bin"
    echo "$nim_workdir_path/bin";;
esac >> "$GITHUB_PATH"
