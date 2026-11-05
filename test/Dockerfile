# The image the tests run in: Node (the test runner, node:test, no packages), Lua 5.1 (the
# WoW client's Lua), luacheck (Alpine's package, on Lua 5.1; config in .luacheckrc), Python 3
# (the release scripts) and git (the tests of the pull-request version
# gate make small repositories). Built from this file alone, no
# context: `docker build - < test/Dockerfile` (scripts/test.sh does it).
#
# The base image is pinned by digest; `docker pull node:24-alpine` and take the new digest
# to move it. tzdata is there so the zip test can really run in other time zones. luacheck is held
# to 1.2.0 (any Alpine revision of it; the base image's Alpine is 3.24): a new luacheck can bring
# new warnings, so moving it is a change of its own.
FROM node:26-alpine@sha256:c6ad9e9c1d80f6eb607c26b4b0a132ff7a2344fad1c78ea3baa2a7d4c8de6d94

RUN apk add --no-cache git lua5.1 luacheck~=1.2.0 python3 tzdata \
 && ln -sf /usr/bin/lua5.1 /usr/local/bin/lua \
 && ln -sf /usr/bin/luac5.1 /usr/local/bin/luac

WORKDIR /w
