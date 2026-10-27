import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { beforeAll, describe, it } from './lib/suite.mjs'
import { expect } from './lib/expect.mjs'

// scripts/fetch-routes.py (wowchar's route API -> toawowchar/Data/Routes.lua) and the file it
// wrote. The script is run on a made-up API answer in a temporary directory (no network); the
// Lua it writes is loaded with Lua 5.1 by test/lua/routes-dump.lua and read back as JSON, so
// what the guide sees is compared with what the API said.
const ROOT = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '')
const STARTS = ['dwarf-gnome', 'human', 'nightelf', 'orc-troll', 'skyborne-a', 'skyborne-h', 'tauren', 'undead']
const KIND = { accept: 1, objective: 2, turnin: 3, travel: 4, grind: 5 }

const temp = () => mkdtempSync(join(tmpdir(), 'toawowchar-routes-'))

function run(cmd, args) {
  const r = spawnSync(cmd, args, { cwd: ROOT, encoding: 'utf8' })
  if (r.error) throw r.error
  return r
}

const fetchRoutes = (...args) => run('python3', ['-I', 'scripts/fetch-routes.py', ...args])

/** The routes file read back through Lua 5.1: { routes, quests, zones, texts, problems }. */
function dump(file) {
  const r = run('lua', ['test/lua/routes-dump.lua', file])
  expect(r.stderr).toBe('')
  expect(r.status).toBe(0)
  return JSON.parse(r.stdout)
}

/** A small API answer for one start, in the shape of wowchar's GET /api/routes/<start>. */
function routeAnswer(startKey) {
  const horde = ['orc-troll', 'undead', 'tauren', 'skyborne-h'].includes(startKey)
  const steps = [
    { n: 1, kind: 'accept', mapId: 12, x: 48.9, y: 40.2, questIds: [33], target: { kind: 'npc', id: 196, name: 'Eagan "the" Peltskinner' }, note: null, level: 1 },
    { n: 2, kind: 'objective', mapId: 12, x: 48.15, y: 39.8, questIds: [33], target: null, note: 'Tough Wolf Meat \\ x8', level: 1 },
    { n: 3, kind: 'turnin', mapId: 12, x: 48.9, y: 40.2, questIds: [33, 7], target: { kind: 'object', id: 5, name: 'Wanted Poster' }, note: null, level: 2 },
    { n: 4, kind: 'travel', mapId: 40, x: 50, y: 50, questIds: [], target: null, note: 'Travel to Westfall', level: 2 },
    { n: 5, kind: 'grind', mapId: 40, x: 50, y: 50, questIds: [], target: null, note: 'Grind to level 3 (about 400 XP)', level: 3 },
  ]
  return {
    route: meta(startKey, horde),
    steps,
    zones: [{ id: 12, name: 'Elwynn Forest', uiMapId: 1429 }, { id: 40, name: 'Westfall', uiMapId: 1436 }],
    quests: [{ id: 33, name: 'Wolves Across the Border', level: 2 }, { id: 7, name: 'Kobold Camp Cleanup — Ünïcode', level: 4 }],
  }
}

function meta(startKey, horde = false) {
  return {
    startKey, faction: horde ? 'H' : 'A', status: 'draft', generatedAt: '2026-10-27T06:00:43.496Z',
    questieVersion: 'v12.1.0+v1.0.6', importLayout: 3, levelEnd: 3, stepCount: 5, confirmed: !startKey.startsWith('skyborne'),
  }
}

/** A directory with index.json and one <start>.json per start; `change(answers)` may break it. */
function apiDir(change = () => {}) {
  const dir = temp()
  const answers = { index: { routes: STARTS.map(k => meta(k, ['orc-troll', 'undead', 'tauren', 'skyborne-h'].includes(k))) } }
  for (const k of STARTS) answers[k] = routeAnswer(k)
  change(answers)
  for (const [name, body] of Object.entries(answers)) writeFileSync(join(dir, `${name}.json`), JSON.stringify(body))
  return dir
}

describe('scripts/fetch-routes.py', () => {
  let out
  let read
  beforeAll(() => {
    out = join(temp(), 'Routes.lua')
    const r = fetchRoutes('--from-dir', apiDir(), '--out', out)
    expect(r.stderr).toBe('')
    expect(r.status).toBe(0)
    expect(r.stdout).toMatch(/^Routes\.lua: 8 routes, 40 steps, 2 quests, \d+ bytes\n$/)
    read = dump(out)
  })

  it('writes Lua 5.1 that loads with nothing but its namespace, and refers to nothing it lacks', () => {
    expect(run('luac', ['-p', out]).status).toBe(0)
    expect(read.problems).toEqual([])
  })

  it('keeps every start, with its faction, Questie version, time and whether its start is confirmed', () => {
    expect(Object.keys(read.routes).sort()).toEqual(STARTS)
    expect(read.routes.human).toMatchObject({ start: 'human', faction: 'A', questie: 'v12.1.0+v1.0.6', generated: '2026-10-27T06:00:43.496Z', confirmed: true, levelEnd: 3 })
    expect(read.routes.undead.faction).toBe('H')
    expect(read.routes['skyborne-a'].confirmed).toBe(false)
    expect(read.routes['skyborne-h'].confirmed).toBe(false)
  })

  it('writes each step as the API has it: kind, the zone\'s uiMapId, x, y, quest ids, target name, level and note', () => {
    const api = routeAnswer('human').steps
    const steps = read.routes.human.steps
    expect(steps).toHaveLength(api.length)
    steps.forEach((s, i) => {
      const a = api[i]
      expect(s).toEqual({
        kind: KIND[a.kind], uiMapId: a.mapId === 12 ? 1429 : 1436, x: a.x, y: a.y, questIds: a.questIds,
        name: a.target ? a.target.name : false, level: a.level, text: a.note ?? false,
      })
    })
  })

  it('keeps the quests\' and maps\' names, with quotes, backslashes and UTF-8 as they are', () => {
    expect(read.quests).toEqual({ 7: 'Kobold Camp Cleanup — Ünïcode', 33: 'Wolves Across the Border' })
    expect(read.zones).toEqual({ 1429: 'Elwynn Forest', 1436: 'Westfall' })
    expect(read.routes.human.steps[0].name).toBe('Eagan "the" Peltskinner')
    expect(read.routes.human.steps[1].text).toBe('Tough Wolf Meat \\ x8')
  })

  it('is the same bytes on every run (sorted, fixed number format, no clock)', () => {
    const again = join(temp(), 'Routes.lua')
    expect(fetchRoutes('--from-dir', apiDir(), '--out', again).status).toBe(0)
    expect(readFileSync(again, 'utf8')).toBe(readFileSync(out, 'utf8'))
  })

  it.each([
    ['a start is missing', a => { a.index.routes = a.index.routes.filter(r => r.startKey !== 'tauren') }, 'no route for tauren'],
    ['an unknown start', a => { a.index.routes.push(meta('pandaren')) }, "startKey 'pandaren'"],
    ['an unknown kind', a => { a.human.steps[1].kind = 'fly' }, "kind 'fly' is not known"],
    ['a map with no zone', a => { a.human.steps[1].mapId = 99 }, 'mapId 99 is not in zones'],
    ['a quest with no name', a => { a.human.steps[0].questIds = [404] }, 'a quest id is not in quests'],
    ['a coordinate off the map', a => { a.human.steps[0].x = 120 }, 'x and y are not 0 to 100'],
    ['a control character', a => { a.human.quests[0].name = 'Bad\nname' }, 'has a control character'],
    ['steps that do not match stepCount', a => { a.human.steps.pop() }, 'not a list of stepCount steps'],
    ['a route that differs from the index', a => { a.human.route.confirmed = false }, 'confirmed differs from /api/routes'],
    ['a quest step without a quest', a => { a.human.steps[0].questIds = [] }, 'a accept step has no quest'],
    ['a zone listed twice', a => { a.human.zones.push({ id: 12, name: 'Elwynn', uiMapId: 9999 }) }, 'zone 12 is listed twice'],
    ['a quest listed twice', a => { a.human.quests.push({ id: 33, name: 'Other', level: 1 }) }, 'quest 33 is listed twice'],
    ['a kind that is not a text', a => { a.human.steps[0].kind = ['accept'] }, 'is not known'],
    ['a time with other digits', a => { a.index.routes[1].generatedAt = '２026-10-27T06:00:43Z' }, 'generatedAt is not an ISO time'],
  ])('refuses %s and writes nothing', (_, change, message) => {
    const file = join(temp(), 'Routes.lua')
    const r = fetchRoutes('--from-dir', apiDir(change), '--out', file)
    expect(r.status).toBe(1)
    expect(r.stderr).toContain(message)
    expect(r.stderr).toContain('nothing was written')
    expect(existsSync(file)).toBe(false)
  })

  it('--uimap lists every uiMapId the client\'s UiMap table does not have, fails and writes nothing', () => {
    const dir = temp()
    const csv = join(dir, 'uimap.csv')
    writeFileSync(csv, 'Name_lang,ID,ParentUiMapID\nElwynn Forest,1429,1415\nDurotar,1411,1414\nshort\n')
    const r = fetchRoutes('--from-dir', apiDir(), '--out', join(dir, 'Routes.lua'), '--uimap', csv)
    expect(r.status).toBe(1)
    expect(r.stderr).toBe('uiMapId 1436 (Westfall) is not in uimap.csv\nerror: a map id the client does not have; nothing was written\n')
    expect(existsSync(join(dir, 'Routes.lua'))).toBe(false)
    expect(r.stdout).toContain('uiMapId check: 2 ids, 1 in uimap.csv, 1 missing')
    writeFileSync(csv, 'Name_lang,ID\nElwynn Forest,1429\nWestfall,1436\n')
    expect(fetchRoutes('--from-dir', apiDir(), '--out', join(dir, 'Routes.lua'), '--uimap', csv).status).toBe(0)
  })
})

describe('toawowchar/Data/Routes.lua (the committed file)', () => {
  let read
  beforeAll(() => { read = dump('toawowchar/Data/Routes.lua') })

  it('loads in Lua 5.1, refers to nothing it lacks, and has every start', () => {
    expect(read.problems).toEqual([])
    expect(Object.keys(read.routes).sort()).toEqual(STARTS)
  })

  it('has the shape of the API: start, faction, Questie version, time, confirmed, and steps of the right types', () => {
    for (const [key, route] of Object.entries(read.routes)) {
      expect(route.start, key).toBe(key)
      expect(['A', 'H'], key).toContain(route.faction)
      expect(route.questie, key).toMatch(/^v\d/)
      expect(route.generated, key).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$/)
      expect(route.confirmed, key).toBe(!key.startsWith('skyborne'))
      expect(route.steps.length, key).toBeGreaterThan(100)
      let level = 1
      route.steps.forEach((s, i) => {
        const at = `${key} step ${i + 1}`
        expect(Object.values(KIND), at).toContain(s.kind)
        expect(Number.isInteger(s.uiMapId) && s.uiMapId > 0, at).toBe(true)
        expect(s.x >= 0 && s.x <= 100 && s.y >= 0 && s.y <= 100, at).toBe(true)
        expect(Array.isArray(s.questIds), at).toBe(true)
        expect(s.questIds.length > 0, at).toBe(s.kind <= 3)
        expect(s.level >= level && s.level <= 60, at).toBe(true)
        level = s.level
      })
      expect(route.levelEnd, key).toBe(level)
    }
  })

  it('names every map and quest it uses', () => {
    const maps = new Set(Object.values(read.routes).flatMap(r => r.steps.map(s => s.uiMapId)))
    expect([...maps].filter(m => !(m in read.zones))).toEqual([])
    expect(Object.keys(read.quests).length).toBeGreaterThan(500)
  })

  it('was written by the script (the header says so)', () => {
    expect(readFileSync(`${ROOT}/toawowchar/Data/Routes.lua`, 'utf8')).toMatch(/^-- The guide's leveling routes, from wowchar/)
  })
})
