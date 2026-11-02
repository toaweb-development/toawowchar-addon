# A-105 — klientprosedyre og proveniens

Dato: 2026-11-02. **Utkast. Alle faktiske klientprøver: NOT TESTED.**
Dette er en manuell gate etter A-102/A-103/A-104, ikke releasegodkjenning.
Webdelen finnes i søsterrepoets `docs/testing/a-105-client-import-gate.md`.
L0 i eierens `TOAWOWCHAR_2_0_CODEX_MASTERPLAN.md` er akseptansegrunnlaget.

## Readonly forundersøkelse

Primæragenten leste installasjon, zip, arbeidskilde og lokal historikk uten å
starte klienten, kjøre Lua eller endre spillfiler. Native researcher vurderte de
oppgitte funnene, men kunne ikke selv lese lokale filer i sin verktøyprofil.

- Installmappe: `/home/torove/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns/toawowchar`.
- Installert TOC sier `Interface: 16001`, `Version: 0.5.0` og
  `SavedVariables: toawowcharDB`. Kopien har 12 filer. `Collect.lua`,
  `Navigation.lua` og `UI/Settings.lua` mangler både fysisk og i TOC.
  Den kan ikke brukes til å bevise A-104-collection eller A-103-navigasjon.
- Installert TOC SHA256:
  `609916a0519f9eecdc412d9594c63d6ec8cf9a89e19be7c76b071f10575867a2`.
- Kandidat: PM-arbeidsmappens `outputs/toawowchar-0.5.0-a104-test.zip`,
  626384 byte, SHA256
  `bf8370747b02f180511d30d3369925a83382c4f881b036327658cb66f7606793`.
  Alle 15 zipfiler er byteidentiske med `toawowchar/` ved arbeidsbase
  `aae2e482952cc06d6ddf347872e2e5da162e45f6`.
  Testet runtime er `4155a8c79f7a5863e57b594e080191b191ca4a39`;
  dokumentasjon følger dette, jf. [A-104](../status/a-104.md).
- Første collector-implementasjon i lokal historikk er `fbb3ac0`, allerede med
  TOC-versjon 0.5.0. Senere rettelser inkluderer `f6f4bdb` og `4155a8c`.
  Første **klientbevist funksjonelle** collector-versjon er ikke fastslått.
  Versjonsnummer alene skiller ikke disse kildevariantene.
- Rekursivt, ikke-skiftsensitivt søk etter `toawowchar.lua` og
  `toawowchar.lua.bak` under eksisterende `_forever_/WTF` ga 0 treff.
  Dette er ingen persistensprøve og utelukker ikke andre spillinstallasjoner.
  Ingen konto-/karakternavn eller SavedVariables-innhold ble rapportert.

Kandidatens TOC-lasterekkefølge (README er den femtende zipfilen):

```text
Locales/enUS.lua
Core.lua
Serializer.lua
Export.lua
Cache.lua
UI/Window.lua
Data/Routes.lua
Waypoint.lua
Guide.lua
Navigation.lua
UI/GuideWindow.lua
Collect.lua
UI/Settings.lua
```

Kandidatens TOC SHA256:
`32677bc1a3510c960460d4dff3f7f3671479e55a54b9194c5c1f8f8cedfc4207`.
Collect.lua SHA256:
`a9b9ac869a8491f38154ff3097a346ee2a6bf587659b0d9e317f84f8f7274949`.
Navigation.lua SHA256:
`5e8856436eda6273c05e311f28617802f70e597675960c05a9c1449e40be2ee5`.

## 1. Sikre utgangspunktet før manuell test

1. Lukk klienten helt. Ta privat backup av eksisterende addonmappe og hele den
   aktuelle SavedVariables-filen med eventuell `.bak`. Noter fravær hvis ingen
   finnes. Ikke slett/reset data for å få testen til å gå. Hold kontoidentitet,
   filinnhold og backup utenfor git, skjermbilder og offentlig rapport.
2. Testoperatøren installerer en ren mappe fra kandidaten etter backup, uten å
   legge den over en blanding av gamle filer. Kontroller riktig `_forever_`-mappe,
   alle zipfiler, TOC og SHA256 på nytt. Noter ziphash, kildecommit og installert
   filhash som separate proveniensfelt. Ingen installasjon er utført av utkastet.
3. Deaktiver andre addons i klientens addonliste. Dokumenter avvik. Slå på
   Lua-feil med `/console scriptErrors 1`; noter gammel innstilling for tilbakeføring.
4. Bekreft faktisk klientversjon/build og interface i klienten med `GetBuildInfo`.
   Eierreglenes eksakte interfacekommando er `/dump select(4, GetBuildInfo())`.
   Forventningen fra TOC er **16001**, ikke et måleresultat. Noter faktisk verdi
   og build separat. Ved mismatch eller «out of date»: stopp og avklar kandidaten;
   ikke endre TOC eller automatisk slå på «Load out of date AddOns».

GetBuildInfo er kildebelagt i Collect.lua sitt API-register, Forever UI-kilde
`ca8368f2f2380cbe696854f7f2646387c278a61b`, BuildDocumentation.lua:10.
Slashsyntaks nedenfor er verifisert mot Core.lua `Command` og spiller-README.
`/wowchar guide` toggler synlighet; `guide off` er ingen støttet av-kommando.

## 2. Eksport og A-102/A-103

1. Kjør `/wowchar` (alias `/toawowchar`). Kontroller vindu, kopiering, prefix
   `WOWCHAR:3:` og gyldig JSON uten `|`. Dekod som data i godkjent lokal flyt.
   `observed` skal ikke sendes. Hold karakteridentitet utenfor evidensrapporten.
2. Kjør `/wowchar guide` og prøv Human/Northshire med et faktisk tilgjengelig
   guidesteg. Kontroller Next/Skip og Back i den eksisterende UI-en. La minst ett
   relevant objective være uferdig: guiden må ikke hoppe til turn-in. Ta før/etter
   ved quest-loggoppdatering og `/reload`. Kontroller A-102s delvis/ukjent match
   dersom en reell quest gir situasjonen; ellers merk akkurat den prøven NOT TESTED.
3. Kontroller pilretning og avstand ved bevegelse/facing, og «Arrived» uten at
   uferdige quests fullføres. Manglende/ugyldig posisjon og naturlig tilgjengelige
   map-/instance-overganger skal skjule gammel pil/avstand og senere gjenoppta.
   Ikke fremprovoser secret values med debugger eller omgå restriksjoner.
4. Prøv kamp inn/ut: ingen usikre oppdateringer/feil, eksport åpner etter kamp,
   nav gjenopptar. `/wowchar settings` åpner innstillinger; test navigasjon av/på,
   guide-at-login separat, skalering og drag/persistens etter reload.
5. Prøv «Map pin» med eget veipunkt før/etter; ingen automatisk overtakelse eller
   gjenoppretting av spillerens markør ved stegbytte. Eksport må fortsatt virke
   når guide/nav er skjult eller deaktivert. En faktisk delfeil skal heller ikke
   blokkere eksport; uten observert delfeil er feilbanen NOT TESTED i klient.
   A-104s feilinjeksjon er offline-evidens, ikke en utført klientprøve.

## 3. Ukjent quest, collector og faktisk diskgrense

1. Åpne `/wowchar settings`; la «Collect quest data» være på. Skjul guiden med
   `/wowchar guide` hvis den vises, og slå «Enable guide navigation» av. Dette
   prøver collection uten aktiv guidevisning/nav; det beviser ikke en delfeil.
2. Velg en **ekte** quest-ID som ikke finnes i kandidatens `Data/Routes.lua`.
   Noter ID og dokumenter statisk fravær fra rutene. Ikke bruk den syntetiske
   W-101/A-104-ID-en som et påstått faktisk oppdrag. Hvis ingen egnet quest er
   tilgjengelig, forblir unknown-quest-kriteriet NOT TESTED.
3. Noter starttellinger i Settings og siste diskøyeblikks anonymiserte metadata.
   Besøk giver, vis/aksepter quest, øk et objective og lever inn. Noter faktiske
   nye giver/start-, objective- og finisher/offer-observasjoner, quest/NPC-ID,
   build og hva som mangler. Anta ikke at en generell tellerøkning beviser alle
   feltene. Objective-punkt etter kamp er spillerposisjon, ikke bevist målposisjon.
4. Ta avlesning før reload og kjør `/reload`. Kontroller samme observasjoner og
   guide/settings/cache etterpå. Ta en privat kopi av filen etter klientens
   skriving; noter tidspunkt, byteantall og SHA256. Les kun statiske Lua-litteraler
   som data; aldri dofile/loadfile/loadstring eller evaluering av filen. Ved
   manuell kontroll kan valgte observed-felt inspiseres privat som tekst uten
   å gjengi realms, navn, råfil eller kontosti i rapporten.
5. Lukk klienten helt og kontroller diskfil igjen. Sammenlign dbVersion 3,
   observed-quests/NPC-er/punkter og den nye questens felter mot før reload.
   Bruk alias som `SV-after-reload` og `SV-after-exit` i rapporten. Hash alene
   beviser bytes, ikke semantisk persistens. Importér den samme hashede kopien
   i webprøven; ikke erstatt den med en syntetisk fixture.
6. Gjenta aktivitet nær samme objective-posisjon og deretter ny posisjon når
   spillet tillater det. Kontroller at duplikater ikke eksploderer, at innsamling
   gjenopptas etter kamp/manglende posisjon, og at collector av/på ikke nuller data.
   Manglende koordinater må aldri fylles med gjetning. Ikke fyll faktisk butikk
   til caps manuelt: 3000 quests/3000 NPC-er/4000 punkter/20 per objective er
   kilde-/offlinebevis fra A-104; klientprøven må beskrive sitt faktiske omfang.

## 4. Rask ytelsesprøve og avslutning

Bruk bare et faktisk tilgjengelig og verifisert klientverktøy for addonprofilering.
Noter verktøynavn/versjon, hvordan det åpnes, måleenhet og om CPU-profilering
krever reload eller endrer målingen. Ingen ny profiler er installert her; ingen
CPU-/memory-slash-API antas. Hvis verktøyet ikke finnes eller ikke gir per-addon
CPU/minne, merk de målingene NOT TESTED fremfor å gjette tall eller kommandoer.

Varm opp. Mål 60 sekunder skjult baseline, 60 sekunder synlig guide/nav,
60 sekunder bevegelse, 60 sekunder nav deaktivert, deretter fem minutter vanlig
questaktivitet. Noter start/slutt og toppminne/CPU hvis verktøyet tilbyr dette,
varighet, andre addons, feil/hakk og om minnet stabiliserer seg. Mål faktisk
SavedVariables-byteantall separat; filstørrelse er ikke klientminne. Dette er en
kort prøve uten fastsatt ytelsesbudsjett og kan ikke alene gi langtids-/capsgodkjenning.

Ved feil: noter trinn og anonymisert feil, stopp berørt prøve og lukk klienten
før tilbakeføring av backup. Ikke endre runtime for å få grønt. Etter testen:
tilbakefør testinnstillinger, behold private bevis sikkert og registrer PASS,
FAIL eller NOT TESTED per rad i [status](../status/a-105.md). Release, pinning,
produksjonskontakt og mainmerge inngår ikke.
