# ADR 001: avgrenset legacyfase før stackmigrering

Dato: 2026-11-02. Status: vedtatt av eieren i P-002.

Behovet er en stabil in-game guide, navigasjon og collector før en separat
stackmigrering. Eieren har uttrykkelig bestemt at eksisterende Nuxt 4/Nitro
bevares for launch. En samtidig omskriving til standardstacken vil utvide
launchens test- og datamigreringsflate; standardens målstack avvises ikke.

Go + Vue/Vite + PostgreSQL 18 blir en egen kontrollert fase etter launch.
Ingen ny stack, tjeneste, database eller avhengighet tas i bruk nå. Addonet
forblir Lua 5.1 i Forever. Dagens webapp bruker PostgreSQL via pg og Battle.net
OAuth; Compose pinner PostgreSQL 18.6 lokalt og 17.11 i produksjonskonfigurasjonen.
Dette er konfigurasjonsfakta, ikke bekreftelse av kjørende produksjonsversjon.

Migreringsfasen krever egen paritetskartlegging av API, data, UI og auth,
backup/restore, datakonsistens og rollback før kontrollert overgang. Den startes
ikke av denne ADR-en. Eksisterende data- og kontrakteierskap bevares.

Instruksjonene følger toaweb-rules v0.14.0 med disse uttrykkelige overgangsavvikene:
Nuxt beholdes; dagens sjekk-/versjonerings-/pakke-/migreringsmekanismer beskrives
slik de finnes. Ingen make verify, release.sh eller deploy.sh innføres i P-002.
Eksisterende workflows beholdes urørt. Webs tag-deploy-workflow kan fortsatt
utløse produksjonsutrulling dersom noen pusher en tag; teksten «inaktiv» gjelder
arbeidsinstruksene, ikke at workflowen teknisk er deaktivert. Ingen push, PR,
release, tag, deploy eller produksjonstilgang er autorisert i P-002.

Overgang til standardens release/deploy og erstatning av app-start-migreringer
er egne avklaringer. Den tidligere aksepterte BiS-konverteringen over 4.0.0
krever særskilt SQL ved rollback; ingen generell automatisk DB-rollback finnes.
Denne ADR-en godkjenner verken nye deploymekanismer eller sletting av workflows.
Se [gjeldende beslutninger](../project-decisions.md) og
[verifikasjon og overlevering](../status/p-002.md).
