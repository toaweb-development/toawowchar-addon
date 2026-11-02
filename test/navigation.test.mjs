import { spawnSync } from 'node:child_process'
import { it } from './lib/suite.mjs'
import { expect } from './lib/expect.mjs'

for (const scenario of ['geometry', 'invalid', 'transitions', 'throttle', 'waypoint', 'settings', 'isolation']) {
  it(`shipped navigation module: ${scenario}`, () => {
    const result = spawnSync('lua', ['test/lua/navigation-test.lua', scenario], { encoding: 'utf8' })
    if (result.error) throw result.error
    expect(result.stderr).toBe('')
    expect(result.status).toBe(0)
    expect(result.stdout.trim()).toBe(`ok ${scenario}`)
  })
}
