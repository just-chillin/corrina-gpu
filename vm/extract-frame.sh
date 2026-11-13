#!/bin/sh
# Pull the frame out of a console log captured from vm/run.sh.
#   vm/extract-frame.sh console.log frame.ppm
sed -n '/^===BEGIN===/,/^===END===/p' "$1" | grep -v '^===' | tr -d '\r' | base64 -d | gunzip > "$2"
