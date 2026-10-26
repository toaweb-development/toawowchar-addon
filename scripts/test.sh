#!/bin/sh
# Runs every test of this repository in Docker: luacheck on the addon (.luacheckrc, zero
# warnings), the Lua tests (Lua 5.1), the checks of the export against the contract, the version
# check and the zip build. Nothing but Docker is needed on the machine.
#
#   scripts/test.sh                      everything (luacheck first)
#   scripts/test.sh test/release.test.mjs   one file (arguments go to `node --test`)
#   UPDATE_FIXTURES=1 scripts/test.sh    write test/fixtures/*.txt again after a deliberate
#                                        change to what the addon exports (then read the diff)
#
# Writes dist/examples/export-format-3.txt (the example export of the release).
set -eu
cd "$(dirname "$0")/.."

image=toawowchar-addon-test
docker build --quiet --tag "$image" - < test/Dockerfile > /dev/null

run() {
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --env HOME=/tmp \
    --env UPDATE_FIXTURES="${UPDATE_FIXTURES:-}" \
    --volume "$PWD":/w \
    "$image" \
    "$@"
}

if [ "$#" -eq 0 ]; then
  # Any warning fails the run (luacheck exits non-zero on warnings).
  run luacheck --no-color --codes toawowchar/
  set -- test/*.test.mjs
fi

mkdir -p dist
run node --test --test-reporter=spec "$@"
