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

  it('the header names the route; a Skyborne route has the orange line under it; a race with no route says so', () => {
    const SKY = '|cffff9933Unconfirmed start. Zephras Isle is our best guess until launch.|r'
    expect(get('window-start', 'human')).toEqual(['human', 'Human route', false, false])
    expect(get('window-start', 'skyborne')).toEqual(['skyborne-a', 'High Order Skyborne route', SKY, false])
    expect(get('window-start', 'skyborne-h')).toEqual(['skyborne-h', 'Windshaper Skyborne route', SKY, false])
    expect(get('window-start', 'none')).toEqual([false, 'Leveling guide', false, 'There is no leveling route for this character\'s race yet.'])
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

  it('shows the current step and the next two; a | in a name is escaped', () => {
    const p = get('window', 'text')
    expect([p.title, p.count, p.quest]).toEqual(['Human route', '|cff9d9d9d1 / 9|r', 'Kobold Camp Cleanup'])
    expect(p.following[0][1]).toBe('|cff9d9d9dWolves || Boars · Marshal Dughan|r')
  })

  it('saves where it was dragged and is there, shown, after a relog; a damaged place falls back to the default', () => {
    expect(get('window', 'point')).toEqual(['TOPLEFT', 'BOTTOMLEFT', 120, 641])
    expect(get('window', 'relog')).toEqual([true, 'TOPLEFT', 'BOTTOMLEFT', 120, 641])
    expect(get('window', 'damaged-point')).toEqual(['RIGHT'])
  })
})

describe('the panel', () => {
  const p = (label) => get('panel', label)
  const grey = (t) => `|cff9d9d9d${t}|r`
  const CHECK = '|A:common-icon-checkmark:12:12:0:0:64:255:64|a'

  it('header and zone line: route name in gold, the count in grey, subzone in light gold · zone, the level', () => {
    const a = p('accept')
    expect([a.title, a.count, a.zone, a.level]).toEqual(['Human route', grey('1 / 9'), '|cffffe8a6Goldshire|r · Elwynn Forest', 'Level 1'])
    expect(p('grind').zone).toBe('Westfall')
  })

  it('accept: the quest-giver icon, ACCEPT, the quest, the NPC in light yellow, light blue coordinates and the distance', () => {
    const a = p('accept')
    expect([a.icon, a.kind, a.quest, a.detail]).toEqual(['QuestNormal', grey('ACCEPT'), 'Kobold Camp Cleanup', '|cffffff9aMarshal Dughan|r'])
    expect([a.coords, a.distance, a.progress]).toEqual(['|cff71d5ff42.1, 65.9|r', '24 yd', 0])
  })

  it('objective: its icon and one line per objective from the quest log, updated on QUEST_LOG_UPDATE; done ones get a green check and grey text', () => {
    const o = p('objective')
    expect([o.icon, o.kind, o.detail, o.objectives]).toEqual(['Navigation-Tracked-Icon', grey('OBJECTIVE'), '|cffffff9aKobold Vermin|r', ['• Kobold Vermin slain: 4/10']])
    expect(p('objective-updated')).toEqual(['• Kobold Vermin slain: 7/10'])
    expect(p('objective-two')).toEqual([[`${CHECK} ${grey('Tough Wolf Meat: 8/8')}`, '• Boar Hide: 2/6'], 26])
  })

  it('turn in: the turn-in icon, TURN IN, both quests, the NPC and every objective checked', () => {
    const t = p('turnin')
    expect([t.icon, t.kind, t.quest, t.detail, t.coords]).toEqual(['UI-QuestIcon-TurnIn-Normal', grey('TURN IN'), 'Kobold Camp Cleanup and Wolves || Boars', '|cffffff9aMarshal Dughan|r', '|cff71d5ff42.1, 65.9|r'])
    expect(t.objectives).toHaveLength(3)
    expect(t.objectives.every(l => l.startsWith(CHECK))).toBe(true)
  })

  it('travel: a light blue arrow, no coordinates or distance, «The guide moves on when you arrive», no timer', () => {
    const [t, noTicker] = p('travel')
    expect([t.icon, t.tint, t.kind, t.quest, t.detail]).toEqual(['poi-traveldirections-arrow', [443, 835, 1000], grey('TRAVEL'), 'Travel to Westfall', false])
    expect([t.coords, t.distance, noTicker]).toEqual([grey('The guide moves on when you arrive'), false, true])
  })

  it('grind: gold swords, the route\'s XP and a bar from the step\'s level to the next step\'s', () => {
    const g = p('grind')
    expect([g.icon, g.tint, g.kind, g.coords, g.xp, g.distance]).toEqual(['countdown-swords', [1000, 820, 0], grey('GRIND'), grey('About 900 XP · or run a dungeon'), 450, false])
    expect(p('grind-xp')).toEqual([900])
  })

  it('the next two steps: a 16 px icon and «Quest · NPC» on one line, cut with an ellipsis', () => {
    expect(p('accept').following).toEqual([['QuestNormal', grey('Wolves || Boars · Marshal Dughan')], ['Navigation-Tracked-Icon', grey('Kobold Camp Cleanup · Kobold Vermin')]])
    const [cut] = p('cut')
    expect(cut[1]).toBe(grey('A very long quest name A very long quest name A v...'))
    expect(p('objective').following[1][1]).toBe(grey('Kobold Camp Cleanup and Wolves || Boars · Marshal...'))
  })

  it('the height follows the content; the progress bar follows the route', () => {
    expect(p('objective').progress).toBe(222)
    expect(p('travel')[0].height).toBeLessThan(p('accept').height)
  })

  it('the distance: a ticker every half second, the game\'s distance to our waypoint while it is super-tracked; it stops when hidden', () => {
    expect(p('ticker')).toEqual([500, 1])
    expect(p('tick')).toEqual(['131 yd'])
    expect(p('not-tracked')).toEqual([false])
    expect(p('accept-again')).toEqual([true, true])
    expect(p('hidden')).toEqual([true])
  })

  it('in combat: the layout stays, the coordinate line says it waits, the timer stops; it all catches up when combat ends', () => {
    const c = (label) => get('panel-combat', label)
    const WAIT = grey('In combat: updates when combat ends')
    expect(c('in-combat')).toEqual([WAIT, false, true, true, true])
    expect(c('step-in-combat')).toEqual([2, true, WAIT])
    expect(c('after-combat')).toEqual(['Wolves || Boars', '|cff71d5ff42.1, 65.9|r', '24 yd', true])
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
    expect(f('start-error')).toEqual([[off('guide', 'route data broken on purpose')], 0, true, true, true])
    expect(f('command-when-off')).toEqual([[off('guide', 'route data broken on purpose'), IS_OFF], true])
  })

  it('in an event handler while shown: the window hides, the guide\'s waypoint is cleared, its events stop', () => {
    const [before, lines, shown, calls, cleared, handled, count, deaf] = f('event-error')
    expect(deaf).toBe(true)
    expect(before).toEqual([true, true])
    expect(lines).toEqual([off('guide', 'settle broke')])
    expect([shown, calls, cleared, handled, count]).toEqual([false, [['clear']], true, 0, 1])
  })

  it('in a button and in /wowchar guide: the same, and the command still answers', () => {
    expect(f('button-error')).toEqual([[off('guide', 'skip broke')], false, true])
    expect(f('command-error')).toEqual([true, [off('guide', 'toggle broke'), IS_OFF]])
  })

  it('in the waypoint: only the waypoint turns off (its marker cleared); the guide goes on without it', () => {
    const [[lines, calls], step, shown, later, guideOff, count] = f('waypoint-error')
    expect(lines).toEqual([off('waypoint', 'super track broke')])
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

describe('the guard itself lets nothing escape', () => {
  const p = (label) => get('part', label)
  const line = (name, message) => `|cff8B7CFFtoawowchar:|r the ${name} hit an error and is turned off for this session: ${message}`

  it('error values that are not text: a table, a table whose tostring raises, nil, blanks', () => {
    expect(p('table')[2].startsWith(line('t', 'table: '))).toBe(true)
    expect(p('table').slice(0, 2)).toEqual([true, true])
    expect(p('bad-tostring')).toEqual([true, true, line('b', 'unknown error')])
    expect(p('nil')).toEqual([true, true, line('n', 'nil')])
    expect(p('empty')).toEqual([true, true, line('e', 'unknown error')])
  })

  it('a cut never splits a character', () => {
    expect(p('utf8')).toEqual([line('u', 'x'.repeat(199) + '...')])
  })

  it('a hook that raises does not stop the next; a hook added when the part is off runs at once', () => {
    expect(p('hooks')).toEqual(['second', 'late'])
  })

  it('a chat frame that raises costs only the line: the call returns and the clean-up ran', () => {
    expect(p('chat-raises')).toEqual([true, true, true])
  })

  it('a window that fails half made is hidden and the guide is off', () => {
    expect(p('half-window')).toEqual([true, true, false, true])
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
