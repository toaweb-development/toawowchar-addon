# Gjeldende prosjektbeslutninger og detaljregister

P-002 flytter kunnskap, ikke materiell betydning av harde eierregler.
[Den tidligere agentguiden](reference/agent-guide-before-p-002.md) er bevart ordrett;
dens prosjektspesifikke harde regler gjelder fortsatt med presiseringene her.
Les detaljseksjonen for berørt område før endringer. Gamle toa-rules-henvisninger
brukes ikke; route/get bruker toaweb-rules v0.14.0.

## Kontrakter og databetydning

- [What lives where](reference/agent-guide-before-p-002.md#what-lives-where): web eier
  eksportformatet i app/shared/addon-export-format.ts, addon-sections.ts og dekoderen
  app/server/utils/addon-export.ts. test/contract.json er en kopi fra dfba6fc, ikke fasit.
  Endring krever koordinering med web først, webaksept før ny addonform, bevar eldre lesing.
  To PR-er var gammel transportprosess; to koordinerte repoendringer er fortsatt nødvendig,
  men P-002 autoriserer ingen PR eller utrulling.
- [Deviations](reference/agent-guide-before-p-002.md#deviations): plain JSON bak WOWCHAR:3:
  uten LibSerialize/LibDeflate og egen deterministisk zip fremfor BigWigs er eierbeslutninger.
- Routes.lua er generert fra web og ikke håndredigert. Shape endres på web først,
  så fetch-routes.py/testene. Genererte ruter er ikke bevis for håndverifisert guide.
- [Rules for work here](reference/agent-guide-before-p-002.md#rules-for-work-here):
  ns.EXPORT_OBSERVED = false bevares (eier 2026-10-27). Den gamle tekstens «Planned»/
  docs/observed-section-henvisning er historisk: webmain dokumenterer nå «defined, not sent».
  Observasjoner går separat fra SavedVariables toawowcharDB.observed, dbVersion 3,
  til admin-import på web. Ny schemaVersion-transport fra masterplanen er ikke innført.
- Collect.lua: 3000 quests, 3000 NPC-er, 4000 punkter totalt, 20 per objective.
  Posisjoner er promille 0..1000; webroutekoordinater er prosent 0..100.
  Ingen registrering i kamp; ingen tid per punkt eller spor, bare first/last som dager
  og build per quest/NPC. NPC-punkt er spillerposisjon ved NPC; kampøkning kan være
  spillerposisjon etter kamp, ikke bevist målposisjon. Manglende posisjon fylles ikke ut
  med gjetning. Ny confidence-/guide-pack-kontrakt er ikke ferdig implementert.
- SavedVariables init/migrering er dbVersion-basert uten reset av brukerdata.
  Ingen arv fra WowcharExportDB. Lua-kode lastes kun fra TOC; eksport bruker egen serializer.
  Utenforgrenser utelates, ikke klippes; ferdige quests er union med cache, aldri tømming.

## Runtime- og eierregler som fortsatt gjelder

[Decisions of the owner](reference/agent-guide-before-p-002.md#decisions-of-the-owner-run-024):
snapshotdelen gjenbygges høyst hvert 5. sekund, første hendelse straks og sammenslått
utløp; kamp utsetter lesing. Ingen snapshot-chat. Turn-in oppdaterer gull/XP;
level-up avleses etter 1 sekund. Behold toawowchar/navn/DB/slashalias.

[Rules for work here](reference/agent-guide-before-p-002.md#rules-for-work-here):
ns.Part isolerer guide/waypoint/collector/settings og nye sidefunksjoner.
part.Call/Wrap omslutter event/slash/click/drag. Første feil varsler én gang og
slår av delen til reload; Fail/OnFail kan ikke kaste. Eksport/cache kaller ikke
inn i delen, og eksportfixture må tåle ødelagt guide. Filkropper bare definisjoner.
Lua 5.1; hvert spillkall beskyttes; .luacheckrc lister nye leste globaler i samme
endring, kun tillatte skrevne globaler og null advarsler. Ikke svekk tester;
UPDATE_FIXTURES er kun for bevisst kontraktendring med lest diff.
Spiller-README skal være sant mot kode og opplyse om utestet klientoppførsel.

[Eierens WoW-regler](wow-addon-rules.md) gjelder med de to dokumenterte unntakene
for serializer og pakking. Forever/Mainline, ikke Classic, verifiser API før bruk,
respekter secrets/protected/kamp, lokaliser spillertekst på engelsk, ingen skjult I/O.
Den gamle generelle CI/releaseprosedyren er inaktiv som oppdrag, ikke slettet kode.

## Pakking, publisering og git

[Release](reference/agent-guide-before-p-002.md#release) bevarer alle fem versjonsfelt,
TOC/ZIP_FILES-samsvar, faste zipbytes, LF, syntetisk hash og aldri erstatning av tag/asset.
Dagens pakke-/scripts-bumpkrav bevares til senere godkjent prosessovergang;
dokumenter/tester uten zipendring trenger ingen bump. Ingen VERSION eller ny releasemekanisme nå.

[CI and workflows](reference/agent-guide-before-p-002.md#ci-and-workflows): bevar
sikkerhetsgrensene: ingen self-hosted runner i offentlig addonrepo, SHA-pinnede actions,
contents:read som default, checkout uten credentials, eventverdier via env,
separat build/read og publish/write. Publish har ikke checkout eller repositorykode,
verifiserer SHA256SUMS og publiserer aldri over eksisterende release. Ingen secrets trengs.
Workflows beholdes urørt i P-002, de er ikke deaktivert av denne teksten.
Gamle PR-, push- og taginstrukser i README/referanse er legacy/inaktive som arbeidsordre.

Eierens commitadresse er `241168682+toaweb@users.noreply.github.com`.
Akseptert gammel historikk med personlige adresser/session-URL-er omskrives ikke.
Ny avhengighet trenger begrunnelse; ingen ny produkt-/sikkerhetsbeslutning innføres her.
Ingen push, PR, release, tag, deploy, workflowstart eller produksjonstilgang i P-002.
Lokal dokumentcommit er uttrykkelig autorisert; tidligere generelt «no commit» er
ikke et hinder for dette. Kontrollert landing av eksisterende runtimearbeid trenger A-101.

[Verified in a real client](reference/agent-guide-before-p-002.md#verified-in-a-real-client)
gjelder bare den oppgitte 0.4.0-testen/build 70450, ikke 0.5.0. Bank/warbank/recipes/
flightmap var ikke fullt testet. 0.5.0 guide, events, waypoint, navigasjonsmarkør og
Skyborne race tokens er ikke klientverifisert. Se [status](status/p-002.md) og
[verifikasjon](verification.md) for gates. Launch er ikke godkjent av dokumentarbeidet.
