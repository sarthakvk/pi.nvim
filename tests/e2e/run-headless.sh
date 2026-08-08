#!/bin/sh
set -eu
project=$(mktemp -d)
trap 'rm -rf "$project"' EXIT
git -C "$project" init -q
printf 'const answer = 42;\n' > "$project/sample.js"
nvim --headless -u NONE -l tests/e2e/headless.lua "$project"
