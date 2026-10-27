# WoW Addon Development (WoW Forever)

> Rule version: 1.0 · Last verified: 2026-10-26 · Target: WoW Forever (Mainline code family)

## 0. Ground truth (read first)

- Target client is **WoW Forever**. It shares Mainline (modern retail) UI architecture and most of the current Mainline API. It is NOT a Classic client.
- **Never use Classic-era API, Classic addon code or Classic tutorials as a reference.** Midnight/Mainline addons are the closest reference.
- Midnight's addon restrictions ("secret values"/addon disarmament) are active in Forever. Assume combat data may be restricted.
- Language is a sandboxed **Lua 5.1**. Not 5.2+, not LuaJIT.

## 1. Verify every API call — no guessing

- Every WoW API function, event, frame method and template used must be verified against:
  1. warcraft.wiki.gg (check the "Game Types" box includes Forever/Mainline), or
  2. Blizzard's UI source (github.com/Gethe/wow-ui-source, matching branch).
- If an API cannot be verified, **say so and stop** — do not invent function names, arguments or return values.
- Prefer namespaced `C_*` APIs over legacy globals (e.g. `C_Container.*`, `C_AddOns.GetAddOnMetadata`, `C_Item.*`, `C_QuestLog.*`). Many old globals are removed.
- When an API may not exist in all builds, use feature detection: `if C_Something and C_Something.Func then`.
- Check API change notes for the current Forever patch on warcraft.wiki.gg before larger changes.

## 2. Lua 5.1 constraints

- No `goto`, no `//` integer division, no native bitwise operators (`&`, `|`, `~`, `<<`) — use the `bit` library.
- No `io`, `os` (except `os.time`/`os.date`/`os.clock`), `require`, `dofile`, `loadfile`, `package`. Files are loaded only via the TOC.
- No network access and no file I/O. The only persistence is SavedVariables.
- Use `select("#", ...)` for vararg count; don't rely on `#` for tables with holes.

## 3. Project structure

```
AddonName/
  AddonName.toc
  AddonName_Mainline.toc   # only if multiple flavors are supported
  Libs/                    # embedded libraries (LibStub style)
  Locales/
  Core.lua
  Data/
  UI/
```

- TOC must contain `## Interface:` matching the current Forever client. **Look up the current value; never hardcode from memory.** Use `/dump select(4, GetBuildInfo())` in game to confirm.
- Use `## Title`, `## Version`, `## Author`, `## SavedVariables` / `## SavedVariablesPerCharacter`, `## IconTexture` as needed.
- File load order is TOC order. Libraries first, then locales, core, modules, UI.
- One responsibility per file.

## 4. Namespace and globals

- Every file starts with `local addonName, ns = ...` and shares state through `ns`.
- Everything is `local` by default. Allowed globals: SavedVariables tables, slash command entries (`SLASH_*`, `SlashCmdList`), and at most one intentional public API table.
- Never overwrite Blizzard globals or functions. Use `hooksecurefunc` (post-hook) instead of replacing.
- Run luacheck with a WoW-aware `.luacheckrc`; zero warnings for accidental globals.

## 5. Events and lifecycle

- Event-driven by default. One event frame per module, dispatch with a table: `frame:SetScript("OnEvent", function(self, event, ...) self[event](self, ...) end)`.
- Initialize SavedVariables on `ADDON_LOADED` (filtered on own addonName), not at file load. Merge defaults without overwriting user data.
- Store a `dbVersion` in SavedVariables and write explicit migrations.
- Unregister events that are no longer needed.
- No `OnUpdate` polling where an event exists. Timers via `C_Timer.After` / `C_Timer.NewTicker`. If `OnUpdate` is required, throttle it.

## 6. Security, combat and restrictions

- Check `InCombatLockdown()` before creating/moving/showing/hiding secure or protected frames; queue changes and apply on `PLAYER_REGEN_ENABLED`.
- Use secure templates (`SecureActionButtonTemplate`, etc.) for anything that casts, targets or uses items.
- Respect secret values: values returned as secrets during restricted contexts can be displayed but not compared, used in arithmetic or as table keys. Check the wiki for the current secret-value API before reading combat/unit data and design features to degrade gracefully.
- Functions requiring a hardware event (e.g. `SendChatMessage` SAY/YELL/EMOTE outside instances) must only be called from direct user input handlers.
- Never attempt to work around protected functions or restrictions.

## 7. Performance

- Cache hot globals as locals at file top (`local UnitLevel = UnitLevel`).
- Reuse tables and frames (pools: `CreateFramePool` / `CreateObjectPool`); avoid creating garbage in frequent handlers.
- Filter high-frequency events early and return fast.
- Do heavy work (large data parsing) in chunks across frames, not in one blocking call.

## 8. Data exchange with external apps

- In-game ↔ out-of-game data goes only through:
  - SavedVariables (written on logout/`/reload` only — never assume real-time), or
  - copy/paste import/export strings (serialize → compress → encode, e.g. LibSerialize + LibDeflate).
- Version every export format and validate on import; reject unknown/malformed data with a clear message.
- Addon-to-addon messaging: `C_ChatInfo.RegisterAddonMessagePrefix` + `C_ChatInfo.SendAddonMessage`, throttled (ChatThrottleLib or equivalent). Trial accounts cannot send addon messages.

## 9. UI

- All user-facing text in English, through a locale table (`L["..."]`) from day one.
- Use built-in templates and mixins where possible; Edit Mode–friendly positioning; save positions in SavedVariables.
- Provide a settings panel via the modern `Settings` API (verify current API) and a slash command.

## 10. Libraries

- Embed libraries in `Libs/` via LibStub; never assume another addon provides them.
- Use only libraries with a Forever/Mainline-compatible release. Pin versions.
- Don't add a library for something that is a few lines of code.

## 11. Tooling and release

- VS Code + Lua Language Server + "WoW API" extension (Ketho) with Forever/Mainline annotations.
- luacheck in CI.
- Release via BigWigs Packager (`.pkgmeta`) on git tag; package to zip.
- Bump `## Interface` and `## Version` on every client patch.

## 12. Testing

- Test with all other addons disabled.
- Enable Lua error display (`/console scriptErrors 1`) or BugSack/BugGrabber.
- Test: fresh install (no SavedVariables), upgrade from previous `dbVersion`, `/reload`, entering/leaving combat, low-level character.
- Debug with `/dump`, `/fstack`, `/etrace`, `/tinspect`.

## 13. When unsure

- Ask or state the uncertainty. A missing feature is better than code built on a non-existent or Classic-only API.
