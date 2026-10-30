import { test } from 'node:test'
import assert from 'node:assert/strict'
import { delta, previousOk } from './fast.js'

test('more instructions than 1% is slower (up)', () => {
	assert.equal(delta(100, 101.5).cls, 'up')
})

test('exactly 1% is not colored', () => {
	assert.equal(delta(100, 99).cls, '')
	assert.equal(delta(100, 101).cls, '')
})

test('fewer instructions than 1% is faster (dn)', () => {
	const d = delta(100, 98)
	assert.equal(d.cls, 'dn')
	assert.equal(d.pct, -2)
})

test('previousOk skips a failed neighbor', () => {
	// newest first, as results.json lists them
	const commits = [
		{ hash: 'c', status: 'ok' },
		{ hash: 'b', status: 'build_failed' },
		{ hash: 'a', status: 'ok' },
	]
	assert.equal(previousOk(commits, 0).hash, 'a')
	assert.equal(previousOk(commits, 2), null)
})
