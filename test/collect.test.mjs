import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, it } from './lib/suite.mjs'
import { expect } from './lib/expect.mjs'

// Quest data collection (Collect.lua), run with Lua 5.1 and stubs of the quest frame, the
// quest log, the map and the world map (test/lua/collect-test.lua).
const ROOT = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '')

const memo = new Map()
function scenario(name) {
  if (!memo.has(name)) {
    const r = spawnSync('lua', ['test/lua/collect-test.lua', name], { cwd: ROOT, encoding: 'utf8' })
    if (r.error) throw r.error
    expect(r.stderr).toBe('')
    expect(r.status).toBe(0)
    memo.set(name, new Map(r.stdout.replace(/\n$/, '').split('\n').map(l => {
      const tab = l.indexOf('\t')
      return [l.slice(0, tab), JSON.parse(l.slice(tab + 1))]
    })))
  }
  return memo.get(name)
}
const get = (name, label) => scenario(name).get(label)

describe('collection: each event records its facts', () => {
  it('QUEST_DETAIL: id, title, level, the summary, the item choices (not a currency), the giver and where the player stands', () => {
    expect(get('events', 'offered')).toEqual({
      id: 501, title: 'The Skyward Path', level: 12, summary: 'Do the thing for Ranger Aelith.',
      choices: [9001, 9002], giver: 70001, start: [2400, 432, 568], first: 20740, last: 20740, build: '70532',
    })
    expect(get('events', 'giver')).toEqual({ id: 70001, name: 'Ranger Aelith', map: 2400, x: 432, y: 568, first: 20740, last: 20740, build: '70532' })
  })

  it('QUEST_ACCEPTED: the objectives from the quest log (text, count needed) and the level', () => {
    expect(get('events', 'accepted')).toEqual([[['Windscale slain: 0/8', 8], ['Feather collected: 0/4', 4]], 12])
  })

  it('an objective that counts up: a point where the player is; the same place again adds nothing', () => {
    expect(get('events', 'points')).toEqual([[[2400, 500, 500], [2400, 600, 550]], [[2400, 610, 400]]])
  })

  it('QUEST_COMPLETE and QUEST_TURNED_IN: the finisher with its place, and the XP and money the game gave', () => {
    expect(get('events', 'turned-in')).toEqual([70002, 1350, 425])
    expect(get('events', 'finisher')).toEqual({ id: 70002, name: 'Elder Myr', map: 2400, x: 400, y: 600, first: 20740, last: 20740, build: '70532' })
  })

  it('facts, not a diary: a first and last day and the build per record, no time per point', () => {
    expect(get('events', 'facts')).toEqual([20740, 20740, '70532', 20740, '70532'])
    for (const p of get('events', 'points').flat()) expect(p).toHaveLength(3)
  })

  it('the world map: its quest offers with their places; QUESTLINE_UPDATE reads the map shown now; closed, nothing', () => {
    expect(get('map', 'requested')).toEqual([2400])
    expect(get('map', 'offers')).toEqual(['Feathers in the Wind', [2400, 250, 750], [2400, 500, 125]])
    expect(get('map', 'update')).toEqual([[2401, 900, 900]])
    expect(get('map', 'closed')).toEqual([true])
  })

  it('inside an instance, with no position or a hidden one: the facts without a position', () => {
    expect(get('no-position', 'instance')).toEqual(['Deep Trouble', 70101, true, 'Captain Holt', true, 0])
    expect(get('no-position', 'no-map')).toEqual([true, true])
    expect(get('no-position', 'hidden')).toEqual([true])
  })

  it('a hidden GUID or an object gives no NPC', () => {
    expect(get('no-position', 'secret-guid')).toEqual([true])
    expect(get('no-position', 'object')).toEqual([true, true])
  })
})

describe('collection: combat and the setting', () => {
  it('nothing is recorded in combat; what counted up is recorded once after it, where the player is', () => {
    expect(get('combat', 'in-combat')).toEqual([true])
    expect(get('combat', 'after-combat')).toEqual([[[2400, 700, 700]], true])
  })

  it('«Collect quest data» off: nothing; on again it starts afresh, then counts as before', () => {
    expect(get('off', 'off')).toEqual([true, 0])
    expect(get('off', 'on-again')).toEqual([0])
    expect(get('off', 'counted')).toEqual([1])
  })
})

describe('collection: points spread over the area, and the size cap', () => {
  it('40 kills across the map keep 20 points from the west end to the east end, not the first 20', () => {
    expect(get('spread', 'spread')).toEqual([20, 320, 900])
    expect(get('spread', 'through-events')).toEqual([20])
  })

  it('a point beside one kept adds nothing; another map is always far', () => {
    expect(get('spread', 'same')).toEqual(['added', false, 'added'])
  })

  it('full: the points of the quest seen longest ago go first; the total stays at the cap; quests and NPCs stay', () => {
    expect(get('cap', 'full')).toEqual([200, 1, 4000, true])
    expect(get('cap', 'after')).toEqual([201, 1, 4000, 18, 20, 2, true])
  })

  it('a zone of 15 quests: 15 quests, 19 NPCs, 480 points, about 15 KB as the export section', () => {
    const [quests, npcs, points, bytes] = get('zone15', 'zone15')
    expect([quests, npcs, points]).toEqual([15, 19, 480])
    expect(bytes).toBeLessThan(20000)
  })
})

describe('collection: an error turns off only the collection', () => {
  it('one chat line; the guide stays on; nothing more is recorded', () => {
    const [lines, collectOff, guideOff] = get('error', 'error')
    expect(lines).toEqual(['|cff8B7CFFtoawowchar:|r the quest data collection hit an error and is turned off for this session: spread broke'])
    expect([collectOff, guideOff]).toEqual([true, false])
    expect(get('error', 'after')).toEqual([true])
  })
})

describe('the export: the «observed» section', () => {
  const PREFIX = 'WOWCHAR:3:'
  const FIXTURE = readFileSync(new URL('./fixtures/export-full.txt', import.meta.url), 'utf8').replace(/\n$/, '')
  const run = (mode) => {
    const r = spawnSync('lua', ['test/lua/export-full.lua', mode], { cwd: ROOT, encoding: 'utf8' })
    if (r.error) throw r.error
    expect(r.stderr).toBe('')
    expect(r.status).toBe(0)
    const [text, chat, state] = r.stdout.replace(/\n$/, '').split('\n')
    return { text, chat: JSON.parse(chat), state: JSON.parse(state) }
  }

  it('as shipped (off): with observations stored, the text is test/fixtures/export-full.txt byte for byte', () => {
    expect(run('observed-off').text).toBe(FIXTURE)
  })

  it('on: the same text with sections.observed added, and nothing else changed (bytes and values)', () => {
    const { text } = run('observed')
    const j = JSON.parse(text.slice(PREFIX.length))
    const observed = j.sections.observed
    expect(observed.source).toBe('live')
    expect(observed.npcs).toEqual([{ build: '70532', first: 20740, id: 70001, last: 20740, map: 2400, name: 'Ranger Aelith', x: 432, y: 568 }])
    expect(observed.quests[0].points).toEqual([[1, 2400, 500, 500], [1, 2400, 600, 550]])
    expect(text.replace(`"observed":${JSON.stringify(observed)},`, '')).toBe(FIXTURE)
    delete j.sections.observed
    expect(j).toEqual(JSON.parse(FIXTURE.slice(PREFIX.length)))
  })

  it('on, with the collection raising: observed is missing, the rest unchanged, collection off, the guide on', () => {
    const { text, chat, state } = run('collect-error')
    const j = JSON.parse(text.slice(PREFIX.length))
    expect(j.sections.observed).toEqual({ source: 'missing', why: 'not_available' })
    delete j.sections.observed
    expect(j).toEqual(JSON.parse(FIXTURE.slice(PREFIX.length)))
    expect(chat.filter(l => l.includes('hit an error'))).toEqual(['|cff8B7CFFtoawowchar:|r the quest data collection hit an error and is turned off for this session: section broken on purpose'])
    expect(state).toEqual(['dwarf-gnome', false, true])
  })
})
