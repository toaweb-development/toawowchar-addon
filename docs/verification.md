# Faktiske sjekker og lokale kommandoer

Fra repo-roten:

| Formål | Eksisterende kommando | Krav / virkning |
|---|---|---|
| Instrukser | `toaweb-mcp check-agents --rules "$TOAWEB_RULES" .` | Read-only dokumentgate |
| Versjonssamsvar | `python3 scripts/check-version.py` | Ingen bump; leser versjons-/TOC-/pakkefiler |
| Dagens fulle testgate | `scripts/test.sh` | Bygger test/Dockerfile, kjører luacheck og Node/Lua-tester; skriver dist/examples |
| Én test via script | `scripts/test.sh test/release.test.mjs` | Bygger image, så én testfil; ingen separat luacheck i dette delvalget |
| Én test uten imagebygg | `docker run --rm --user "$(id -u):$(id -g)" --env HOME=/tmp --volume "$PWD":/w toawowchar-addon-test node --test --test-reporter=spec test/release.test.mjs` | Krever eksisterende korrekt image fra test/Dockerfile; skriver bare lokale testartefakter |
| Zip lokalt | `python3 scripts/build-zip.py` | Skriver dist/, ingen publisering; ikke kjørt i P-002 |

scripts/test.sh er ingen ny make verify. Ingen Makefile, StyLua- eller check-agents-
fullgate er etablert i dette repoet. Eksisterende testsuite dekker blant annet
Lua 5.1-syntaks, fixtures og pakking; P-001-baseline gjenbrukes for dokumentendringen.
Ingen scripts/fetch-routes.py, release, oppstart eller destruktiv kommando kjøres
bare fordi den er nevnt i README eller referanse.

Full runtimegodkjenning trenger også virkelig Forever-klient: build/interface,
reload, kamp inn/ut, guide/collector/navigasjon, persistens og CPU/minne. 0.5.0 er
ikke testet slik. [Status](status/p-002.md) skiller P-001-baseline fra nye P-002-sjekker.
