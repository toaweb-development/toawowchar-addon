# toawowchar-addon

Lua 5.1-addon for World of Warcraft: Forever med karaktereksport, guide og collector.
Prosjektinstruksene følger toaweb-rules v0.14.0 med
[dokumenterte overgangsavvik](docs/decisions/001-launch-before-stack-migration.md).

## Slik finner du reglene

- Bruk toaweb-mcp: route med oppgaven, så get av nødvendige wow-addon-seksjoner.
- Bruk relevante toaweb-skills; instruksjonsvedlikehold: toaweb-maintaining-agents-md.
- Uten MCP: les nødvendige seksjoner i lokal toaweb-rules/standards og rapporter avviket.
- Les [prosjektbeslutninger](docs/project-decisions.md) og [eierens addonregler](docs/wow-addon-rules.md).
  Gammel agentguide er bevart via beslutningsoversikten; harde eierregler gjelder fortsatt.
- [README](README.md) har utviklerkommandoer; [status](docs/status/p-002.md) har oppgaver/gates.

## Kommandoer

Fra repo-roten; TOAWEB_RULES peker på gjeldende rules-checkout:

| Formål | Kommando |
|---|---|
| Instruksjonsgate | `toaweb-mcp check-agents --rules "$TOAWEB_RULES" .` |
| Versjonssamsvar | `python3 scripts/check-version.py` |
| Én test, eksisterende lokalt image | `docker run --rm --user "$(id -u):$(id -g)" --env HOME=/tmp --volume "$PWD":/w toawowchar-addon-test node --test --test-reporter=spec test/release.test.mjs` |

Testkommandoen krever allerede bygget image fra test/Dockerfile, ikke en vilkårlig ny pull.
[Test-/fullcheckoversikten](docs/verification.md) beskriver scripts/test.sh og lokale bygg.
make verify finnes ikke; dagens tester er ikke et bevis for klient, reload eller CPU/minne.

## Ufravikelige regler

- Web eier format 3 og ruter. test/contract.json er en kopi; aldri endre bare kopien for å få grønt.
  Webaksept utvides før addonet sender ny form; eldre formater beholdes på web.
- Eksporten er plain JSON bak WOWCHAR:3:, egen serializer, uten LibSerialize/LibDeflate.
  Ingen | i kopiboksen. Verdier utenfor grensene utelates, ikke klippes. Ferdige quests bare vokser.
- Observed-teksteeksport forblir av etter eierbeslutning. dbVersion 3-observasjoner
  importeres separat fra SavedVariables; ikke reset gamle data for å migrere.
- Collectors caps og kildebetydning bevares, se prosjektbeslutningene. Ingen registrering i kamp;
  observasjoner er fakta med kildebegrensninger, ikke en dagbok eller automatisk rutefasit.
- Snapshot strupes til 5 sekunder; quest turn-in oppdaterer også gull/XP;
  level leses 1 sekund etter PLAYER_LEVEL_UP. Dette er tilsiktet eierbestemt oppførsel.
- Nye sidefunksjoner isoleres med ns.Part/part.Call/part.Wrap; feil slår av bare delen.
  Eksport/cache må fungere uavhengig; Fail/OnFail må ikke kaste. Filkropper holdes til definisjoner.
- Lua 5.1, beskyttede spillkall og null luacheck-advarsler; nye leste API-globaler i .luacheckrc.
  Ikke omgå hemmelige verdier eller kamprestriksjoner. Ikke svekk tester; les tilsiktet fixturediff.
- Data/Routes.lua er webgenerert og redigeres ikke for hånd.
- Deterministisk zip med scripts/build-zip.py beholdes. ZIP_FILES og TOC endres samlet.
  Publiserte assets/tagger erstattes aldri; full pakke-/workflowregel er lenket i beslutningene.
- Addonnavn, SavedVariables og slashalias beholdes; ingen overtakelse fra WowcharExportDB.
- Spiller-README skal stemme med koden; 0.5.0 er ikke verifisert i faktisk klient.
- Endrer du kommandoer, verktøy eller regler, oppdater AGENTS.md i samme commit.

## Spør eieren før du

- endrer materiell betydning av harde eierregler eller disse to regelseksjonene,
- endrer kontrakter uten koordinering med web, eller legger til en avhengighet uten begrunnelse,
- gjør publisering eller endrer release-/deploymekanismer.

## Git

- Egen lokal feat/, fix/ eller chore/-gren; Conventional Commits på engelsk, små bokstaver.
- Commits bruker eierens GitHub noreply-adresse; eksisterende akseptert historikk omskrives ikke.
- Ingen push, PR, tag, release, workflowstart, deploy eller produksjonstilgang uten uttrykkelig oppdrag.
- Dokumentarbeid krever ingen versjonsbump. Bevar dagens femfelts versjons-/pakkegrenser.
- Landing krever godkjent scope og grønne relevante gates; se status før landing av uverifisert arbeid.
