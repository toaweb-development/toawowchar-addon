import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, it } from './lib/suite.mjs'
import { expect } from './lib/expect.mjs'

// The leveling guide (Guide.lua, Waypoint.lua, UI/GuideWindow.lua), run with Lua 5.1 on the
// made-up route of test/lua/guide-test.lua (nine steps: two accepts, two objectives, a turn-in
// of both quests, a travel to Westfall, a grind to level 5, an accept and a turn-in), with stubs
// of the quest log, the map and the waypoint API.
const ROOT = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '')

const memo = new Map()
function scenario(name) {
  if (!memo.has(name)) {
    const r = spawnSync('lua', ['test/lua/guide-test.lua', name], { cwd: ROOT, encoding: 'utf8' })
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

describe('the guide: the start comes from the race', () => {
  it('maps every race token to its start; any Skyborne token goes by faction; anything else has no route', () => {
    const keys = Object.fromEntries(get('start', 'keys').map(([race, faction, key]) => [`${race}/${faction}`, key]))
    expect(keys).toEqual({
      'Human/Alliance': 'human',
      'Dwarf/Alliance': 'dwarf-gnome',
      'Gnome/Alliance': 'dwarf-gnome',
      'NightElf/Alliance': 'nightelf',
      'Orc/Horde': 'orc-troll',
      'Troll/Horde': 'orc-troll',
      'Scourge/Horde': 'undead',
      'Tauren/Horde': 'tauren',
      'HighOrderSkyborne/Alliance': 'skyborne-a',
      'WindshaperSkyborne/Horde': 'skyborne-h',
      'Skyborne/Alliance': 'skyborne-a',
      'Skyborne/Horde': 'skyborne-h',
      'Skyborne/Neutral': false,
      'Harronir/Alliance': false,
      'Pandaren/Neutral': false,
    })
    expect(get('start', 'not-a-string')).toEqual([false])
  })

  it('the window names the start; a Skyborne route says «unconfirmed start»; a race with no route says so', () => {
    const [human, humanText] = get('window-start', 'human')
    expect(human).toBe('human')
    expect(humanText[0]).toContain('Human')
    expect(humanText.join('\n')).not.toContain('unconfirmed start')
    for (const label of ['skyborne', 'skyborne-h']) {
      const [key, text] = get('window-start', label)
      expect(key).toBe(label === 'skyborne' ? 'skyborne-a' : 'skyborne-h')
      expect(text[0]).toContain('unconfirmed start')
    }
    expect(get('window-start', 'none')).toEqual([false, ['Leveling guide', 'There is no leveling route for this character\'s race yet.']])
  })
})

describe('the guide: login and /reload skip to the first step whose quests are not all done', () => {
  it.each([
    ['fresh', 1, 'nothing done: the first accept'],
    ['one-accepted', 2, 'quest 101 in the log: its accept is done'],
    ['both-accepted', 3, 'both in the log: the first objective'],
    ['objective-done', 4, '101 ready to turn in, one of 102\'s two objectives done: 102\'s objective step'],
    ['turned-in-elwynn', 6, 'both turned in, still in Elwynn: the travel step before the next quest'],
    ['turned-in-westfall', 7, 'in Westfall at level 4: the grind (the next step wants 5)'],
    ['turned-in-level5', 8, 'in Westfall at level 5: the next accept'],
    ['out-of-order', 1, 'a later quest done does not jump past an earlier one'],
  ])('%s -> step %i (%s)', (label, step) => {
    expect(get('login', label)).toEqual([step])
  })

  it('a finished route is past its last step', () => {
    expect(get('login', 'all-done')).toEqual([10, 9])
  })

  it('a quest log that is still empty when the world is entered: the first quest log update finds the place again', () => {
    expect(get('login', 'late-log')).toEqual([1, 3])
  })
})

describe('the guide: each kind of step moves on with its own event', () => {
  const trail = () => Object.fromEntries(get('advance', 'trail'))

  it('accept on QUEST_ACCEPTED, once every quest of the step is in the log', () => {
    expect(trail()['log-update-nothing']).toBe(1)
    expect(trail()['accepted-101']).toBe(2)
    expect(trail()['accepted-102']).toBe(3)
  })

  it('objective when the step\'s objectives are done (another unit\'s quest log changing is ignored; one of two is not enough)', () => {
    expect(trail()['other-unit']).toBe(3)
    expect(trail()['kobolds-done']).toBe(4)
    expect(trail()['one-of-two']).toBe(4)
    expect(trail().both).toBe(5)
  })

  it('turn-in on QUEST_TURNED_IN, once every quest of the step is turned in (before the game\'s flag is set)', () => {
    expect(trail()['turned-in-101']).toBe(5)
    expect(trail()['turned-in-102']).toBe(6)
  })

  it('travel when the player is on the step\'s map, or a map inside it', () => {
    expect(trail()['zone-changed-still-elwynn']).toBe(6)
    expect(trail().westfall).toBe(7)
    expect(get('advance', 'town-in-elwynn')).toEqual([7, true])
  })

  it('grind when the level reaches the next step\'s level (PLAYER_LEVEL_UP\'s level counts even when UnitLevel is late)', () => {
    expect(trail()['level-4']).toBe(7)
    expect(trail()['level-5']).toBe(8)
  })

  it('goes through to the end, and saves the step per character with the route it belongs to', () => {
    expect(trail()['accepted-201']).toBe(9)
    expect(trail().done).toBe(10)
    expect(get('advance', 'saved')).toEqual({ route: 'human', generated: '2026-10-27T06:00:43.496Z', step: 10, skipped: [] })
  })
})

describe('the guide: Skip, Back and Hide', () => {
  it('has the three buttons', () => {
    expect(get('buttons', 'labels')).toEqual([true, true, true])
  })

  it('Skip marks the step skipped and moves on; Back goes back, un-skips it and holds there', () => {
    expect(get('buttons', 'skip')).toEqual([2, [1]])
    expect(get('buttons', 'back')).toEqual([1, true, []])
    expect(get('buttons', 'held')).toEqual([1])
    expect(get('buttons', 'skip-after-back')).toEqual([2, false])
  })

  it('a relog keeps the skipped steps; a new route (another generated time) forgets them', () => {
    expect(get('buttons', 'relog')).toEqual([2, 2, [1]])
    expect(get('buttons', 'new-route')).toEqual([1])
  })

  it('Hide hides the window and saves that it is hidden', () => {
    expect(get('buttons', 'hidden')).toEqual([false, false])
  })
})

describe('the guide window', () => {
  it('is hidden until /wowchar guide, which shows it and saves that', () => {
    expect(get('window', 'before-command')).toEqual([false])
    expect(get('window', 'after-command')).toEqual([true, true])
    expect(get('window', 'toggled')).toEqual([false, false])
  })

  it('shows the current step and the next two with their /way lines; a | in a name is escaped', () => {
    const text = get('window', 'text')
    expect(text[1]).toContain('1/9')
    const rows = text.slice(2)
    expect(rows).toHaveLength(3)
    expect(rows[0]).toContain('Accept|r  Kobold Camp Cleanup from Marshal Dughan')
    expect(rows[0]).toContain('/way Elwynn Forest 42.1 65.9  level 1')
    expect(rows[1]).toContain('Wolves || Boars from Marshal Dughan')
    expect(rows[2]).toContain('Do  Kobold Vermin for Kobold Camp Cleanup')
    expect(rows[2]).toContain('/way Elwynn Forest 61.0 47.5  level 2')
  })

  it('saves where it was dragged and is there, shown, after a relog; a damaged place falls back to the default', () => {
    expect(get('window', 'point')).toEqual(['TOPLEFT', 'BOTTOMLEFT', 120, 641])
    expect(get('window', 'relog')).toEqual([true, 'TOPLEFT', 'BOTTOMLEFT', 120, 641])
    expect(get('window', 'damaged-point')).toEqual(['RIGHT'])
  })
})

describe('the guide: the game\'s waypoint', () => {
  it('none while the guide is hidden; shown: a user waypoint on the step\'s map and coordinates, super-tracked', () => {
    expect(get('waypoint', 'hidden-no-waypoint')).toEqual([])
    expect(get('waypoint', 'shown')).toEqual([['set', 1429, 421, 659], ['track', true]])
    expect(get('waypoint', 'next-step')).toEqual([['set', 1429, 421, 659], ['track', true]])
  })

  it('cleared when the guide is hidden, but never a waypoint the player placed', () => {
    expect(get('waypoint', 'hidden')).toEqual([[['clear']], false])
    expect(get('waypoint', 'players-own')).toEqual([[], true])
  })

  it('a grind step too (the middle of its zone); on a map the game refuses the guide\'s old one is cleared; it works without the waypoint API', () => {
    expect(get('waypoint', 'grind')).toEqual([7, [['set', 1436, 500, 500], ['track', true]]])
    expect(get('waypoint', 'refused-map')).toEqual([8, [['set', 1436, 500, 500], ['track', true], ['clear']], false])
    expect(get('waypoint', 'no-api')).toEqual([1, true])
  })
})

describe('the guide in combat', () => {
  it('no frame is made, shown, hidden, redrawn or dragged in combat; it happens when combat ends', () => {
    expect(get('combat', 'in-combat')).toEqual([false, false, true])
    expect(get('combat', 'after-combat')).toEqual([true])
    expect(get('combat', 'step-in-combat')).toEqual([2, true])
    expect(get('combat', 'drag-in-combat')).toEqual([false])
    expect(get('combat', 'hide-in-combat')).toEqual([true])
    expect(get('combat', 'hidden-after')).toEqual([false])
  })
})

describe('a guide or waypoint that hits an error: one chat line, that part off until /reload', () => {
  const LABEL = '|cff8B7CFFtoawowchar:|r '
  const off = (what, message) => `${LABEL}the ${what} hit an error and is turned off for this session: ${message}`
  const IS_OFF = `${LABEL}the guide is turned off for this session after an error. /reload turns it on again.`
  const f = (label) => get('failsafe', label)

  it('at its start: one line with the error, then no handler runs; /wowchar guide says it is off', () => {
    expect(f('start-error')).toEqual([[off('guide', 'test/lua/guide-test.lua:445: route data broken on purpose')], 0, true, true])
    expect(f('command-when-off')).toEqual([[off('guide', 'test/lua/guide-test.lua:445: route data broken on purpose'), IS_OFF], true])
  })

  it('in an event handler while shown: the window hides, the guide\'s waypoint is cleared, its events stop', () => {
    const [before, lines, shown, calls, cleared, handled, count] = f('event-error')
    expect(before).toEqual([true, true])
    expect(lines).toEqual([off('guide', 'test/lua/guide-test.lua:464: settle broke')])
    expect([shown, calls, cleared, handled, count]).toEqual([false, [['clear']], true, 0, 1])
  })

  it('in a button and in /wowchar guide: the same, and the command still answers', () => {
    expect(f('button-error')).toEqual([[off('guide', 'test/lua/guide-test.lua:479: skip broke')], false, true])
    expect(f('command-error')).toEqual([true, [off('guide', 'test/lua/guide-test.lua:487: toggle broke'), IS_OFF]])
  })

  it('in the waypoint: only the waypoint turns off (its marker cleared); the guide goes on without it', () => {
    const [[lines, calls], step, shown, later, guideOff, count] = f('waypoint-error')
    expect(lines).toEqual([off('waypoint', 'test/lua/guide-test.lua:495: super track broke')])
    expect(calls).toEqual([['set', 1429, 421, 659], ['clear']])
    expect([step, shown, later, guideOff, count]).toEqual([3, true, [], false, 1])
  })

  it('the line has no escape code (every | doubled), no line break, and is cut at 200 bytes', () => {
    const [line] = f('message')
    expect(f('message')).toHaveLength(1)
    const message = line.slice(off('guide', '').length)
    expect(message.startsWith('a ||cffff0000red||r line with a newline xxx')).toBe(true)
    expect(message).not.toContain('\n')
    expect(message.replace(/\|\|/g, '|').length).toBe(203)
    expect(message.endsWith('x...')).toBe(true)
  })

  it('a new session has the guide again, shown as it was saved', () => {
    expect(f('after-reload')).toEqual([false, true, true, 0])
  })
})

describe('the export and the cache do not depend on the guide', () => {
  const FIXTURE = readFileSync(new URL('./fixtures/export-full.txt', import.meta.url), 'utf8').replace(/\n$/, '')
  const run = (mode) => {
    const r = spawnSync('lua', ['test/lua/export-full.lua', mode], { cwd: ROOT, encoding: 'utf8' })
    if (r.error) throw r.error
    expect(r.stderr).toBe('')
    expect(r.status).toBe(0)
    const [text, chat, state] = r.stdout.replace(/\n$/, '').split('\n')
    return { text, chat: JSON.parse(chat), state: JSON.parse(state) }
  }

  it.each([
    ['guide-start-error', false, 'the guide fails at its start (its route data raises)'],
    ['guide-event-error', 'dwarf-gnome', 'the guide starts on its real route, then fails in an event handler'],
  ])('%s: /wowchar gives the same text as test/fixtures/export-full.txt (%s)', (mode, key) => {
    const { text, chat, state } = run(mode)
    expect(text).toBe(FIXTURE)
    expect(state).toEqual([key, true])
    const hit = chat.filter(l => l.includes('hit an error'))
    expect(hit).toHaveLength(1)
    expect(hit[0]).toContain('the guide hit an error and is turned off for this session: ')
    // the bank and the flight map, read after the guide failed, are still saved
    expect(chat).toContain('|cff8B7CFFtoawowchar:|r saved 3 flight paths.')
  })
})

describe('SavedVariables dbVersion 2', () => {
  it('migrates 0.4.x\'s table (realms at the top) under realms, keeping the cache', () => {
    expect(get('migration', 'migrated')).toEqual([2, true, [3, 9], true])
  })

  it('leaves a table with a newer dbVersion untouched and works on a table of this session', () => {
    expect(get('migration', 'newer')).toEqual([9, [1], true, true])
  })
})
