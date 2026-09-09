const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const sourcePath = path.resolve(__dirname, '..', 'vsdiretor.js')
const source = fs.readFileSync(sourcePath, 'utf8').replace(/\r\n/g, '\n')

function extract(name) {
  const start = source.search(new RegExp(`  function ${name}\\(`))
  assert(start >= 0, name)
  const tail = source.slice(start + 1).search(/\n  (?:async )?function /)
  assert(tail >= 0, name)
  return source.slice(start, start + 1 + tail)
}

let item = null
const context = vm.createContext({
  state: { snapshot: {}, lastGoodAt: 1000 },
  Number, Math,
  isPlaying: data => data?.playing === true,
  isPaused: data => data?.paused === true,
  getVisualPlayingId: data => String(data?.playingId || ''),
  getPlayingId: data => String(data?.playingId || ''),
  getQueuedId: data => String(data?.queuedId || ''),
  getSongItemById: id => id ? item : null,
  getSmoothedCurrentPlaybackPosition: data => data?.position ?? null,
  getItemStart: value => value?.start ?? null,
  getItemEnd: value => value?.end ?? null,
  getDurationSec: value => Number(value?.durationSec) || 0,
  getVisualPlaybackProgressPercent: data => Number(data?.progress) || 0,
  now: () => 1000,
  formatTime(seconds) {
    const value = Math.max(0, Math.floor(Number(seconds) || 0))
    return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, '0')}`
  },
})

for (const name of [
  'firstValidIndividualTimeSec',
  'getVisualPlayingRemainingSec',
  'getQueuedSongDurationSec',
  'formatIndividualRemainingTime',
]) vm.runInContext(extract(name), context)

context.data = {
  playing: true, playingId: 'playing', playbackRemainingSec: null,
  currentSongRemainingSec: 30,
}
assert.equal(vm.runInContext('getVisualPlayingRemainingSec(data, 3000)', context), 28)
context.data.paused = true
context.data.playing = false
assert.equal(vm.runInContext('getVisualPlayingRemainingSec(data, 3000)', context), 30)

item = null
context.data = {
  playing: true, playingId: 'playing', playbackRemainingSec: null,
  currentSongRemainingSec: null, playbackDurationSec: 120, progress: 25,
}
assert.equal(vm.runInContext('getVisualPlayingRemainingSec(data, 1000)', context), 90)

item = { durationSec: 0, start: 10, end: 70 }
context.data = { queuedId: 'queued' }
assert.equal(vm.runInContext('getQueuedSongDurationSec(data)', context), 60)
item = null
context.data = {
  queuedId: 'queued', queuedStartPos: null, queueStartPos: 10,
  queuedEndPos: null, queueEndPos: 85,
}
assert.equal(vm.runInContext('getQueuedSongDurationSec(data)', context), 75)

assert.equal(vm.runInContext('formatIndividualRemainingTime(60.0000001)', context), '1:00')
assert.equal(vm.runInContext('formatIndividualRemainingTime(60.2)', context), '1:01')
assert.equal(vm.runInContext('formatIndividualRemainingTime(null)', context), '')
assert(source.includes('const progress = isPlaying(data) || isPaused(data)'))
assert(source.includes('.item.queuedYellow:not(.blockItem) .queuedYellowTimeText'))

console.log(`DIRECTOR_INDIVIDUAL_TIME_OK: ${sourcePath}`)
