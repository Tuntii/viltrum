// The fast page: draws results.json (benches/fast/results.py publish) as one
// small chart per scenario and a table, newest commit first.

export const SCENARIOS = [
	['baseline', 'baseline', 'GET /baseline11'],
	['json', 'json', 'GET /json/50, gzip'],
	['pipelined', 'pipelined', 'GET /pipeline ×16'],
]

const REPO = 'https://github.com/Tuntii/viltrum'
const SVG = 'http://www.w3.org/2000/svg'

// delta compares two Ir/request values. More instructions is slower ("up").
export function delta(prev, cur) {
	const pct = ((cur - prev) / prev) * 100
	return { pct, cls: pct > 1 ? 'up' : pct < -1 ? 'dn' : '' }
}

// previousOk is the nearest older commit that was measured; commits are newest first.
export function previousOk(commits, i) {
	for (let j = i + 1; j < commits.length; j++) {
		if (commits[j].status === 'ok') return commits[j]
	}
	return null
}

const fmt = (n) => Math.round(n).toLocaleString('en-US').replace(/,/g, ' ')
const fmtRps = (n) => (n >= 1e6 ? (n / 1e6).toFixed(2) + 'M' : n >= 1e3 ? Math.round(n / 1e3) + 'k' : String(n))

function el(doc, tag, attrs = {}, text) {
	const e = doc.createElement(tag)
	for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v)
	if (text !== undefined) e.textContent = text
	return e
}

function svg(doc, tag, attrs) {
	const e = doc.createElementNS(SVG, tag)
	for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v)
	return e
}

function chart(doc, commits, key, label, what) {
	const old = [...commits].reverse() // oldest first, left to right
	const vals = old.filter((c) => c.status === 'ok').map((c) => c.ir[key])
	const box = el(doc, 'figure', { class: 'chart' })
	const last = commits.find((c) => c.status === 'ok')
	const head = el(doc, 'figcaption')
	head.append(el(doc, 'b', {}, label), el(doc, 'span', { class: 'what' }, what))
	if (last) head.append(el(doc, 'span', { class: 'now' }, fmt(last.ir[key]) + ' Ir/req'))
	box.append(head)
	if (!vals.length) return box
	const W = 300, H = 90, P = 6
	let lo = Math.min(...vals), hi = Math.max(...vals)
	if (hi === lo) { lo -= 1; hi += 1 }
	const x = (i) => (old.length === 1 ? W / 2 : P + (i * (W - 2 * P)) / (old.length - 1))
	const y = (v) => H - P - ((v - lo) * (H - 2 * P)) / (hi - lo)
	const s = svg(doc, 'svg', { viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': `${label}: instructions per request by commit` })
	let run = []
	const flush = () => {
		if (run.length > 1) s.append(svg(doc, 'polyline', { points: run.join(' '), class: 'line' }))
		run = []
	}
	old.forEach((c, i) => {
		if (c.status !== 'ok') return flush() // a failed build is a gap
		run.push(`${x(i).toFixed(1)},${y(c.ir[key]).toFixed(1)}`)
	})
	flush()
	old.forEach((c, i) => {
		if (c.status !== 'ok') return
		const dot = svg(doc, 'circle', { cx: x(i).toFixed(1), cy: y(c.ir[key]).toFixed(1), r: 2.2, class: c.version ? 'dot rel' : 'dot' })
		const t = svg(doc, 'title', {})
		t.textContent = `${c.hash.slice(0, 7)}${c.version ? ' ' + c.version : ''}: ${fmt(c.ir[key])} Ir/req\n${c.subject}`
		dot.append(t)
		s.append(dot)
	})
	const scale = el(doc, 'div', { class: 'scale' })
	scale.append(el(doc, 'span', {}, fmt(hi)), el(doc, 'span', {}, fmt(lo)))
	box.append(s, scale)
	return box
}

function cell(doc, c, prev, key) {
	const td = el(doc, 'td', { class: 'num' })
	if (c.status !== 'ok') return td
	td.append(el(doc, 'span', {}, fmt(c.ir[key])))
	if (prev) {
		const d = delta(prev.ir[key], c.ir[key])
		if (d.cls) td.append(el(doc, 'span', { class: 'd ' + d.cls }, (d.pct > 0 ? '+' : '') + d.pct.toFixed(1) + '%'))
	}
	return td
}

export function render(doc, data) {
	const commits = data.commits
	const charts = doc.getElementById('charts')
	for (const [key, label, what] of SCENARIOS) charts.append(chart(doc, commits, key, label, what))

	const body = doc.getElementById('rows')
	commits.forEach((c, i) => {
		const tr = el(doc, 'tr', c.status === 'ok' ? {} : { class: 'failed' })
		const h = el(doc, 'td', { class: 'hash' })
		h.append(el(doc, 'a', { href: `${REPO}/commit/${c.hash}` }, c.hash.slice(0, 7)))
		tr.append(h, el(doc, 'td', { class: 'date' }, c.date.slice(0, 10)))
		const msg = el(doc, 'td', { class: 'msg', title: c.subject })
		if (c.version) msg.append(el(doc, 'span', { class: 'badge' }, c.version))
		msg.append(el(doc, 'span', {}, c.subject))
		tr.append(msg)
		if (c.status === 'ok') {
			const prev = previousOk(commits, i)
			for (const [key] of SCENARIOS) tr.append(cell(doc, c, prev, key))
			tr.append(el(doc, 'td', { class: 'num rps' }, SCENARIOS.map(([k]) => fmtRps(c.rps[k])).join(' / ')))
		} else {
			tr.append(el(doc, 'td', { class: 'num status', colspan: SCENARIOS.length + 1 }, c.status.replace('_', ' ')))
		}
		body.append(tr)
	})
	doc.getElementById('setup').textContent = data.setup
	doc.getElementById('count').textContent = commits.length
}
