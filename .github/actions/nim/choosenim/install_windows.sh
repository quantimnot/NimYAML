#!/bin/sh

set -Cue

# Params
choosenim_version="$1"
choosenim_path="$2"

eval choosenim_path=$choosenim_path

# From zip
# choosenim_archive="choosenim-${choosenim_version#v*}_windows_amd64.zip"
# From exe
choosenim_archive="choosenim-${choosenim_version#v*}_windows_amd64.exe"
choosenim_url="https://github.com/dom96/choosenim/releases/download/$choosenim_version/$choosenim_archive"

# Fetch and extract choosenim
curl -LO "$choosenim_url"

# Install from zip
# unzip "$choosenim_archive"
# cmd /c runme.bat

# Install from exe
mv "$choosenim_archive" "$choosenim_path/bin/choosenim"
