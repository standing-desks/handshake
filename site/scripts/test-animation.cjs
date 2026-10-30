// Drive the shipped animation code with controlled display timestamps.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const read = name => fs.readFileSync(path.join(__dirname, '..', 'src', name), 'utf8');

function heroFixture(reduced = false) {
  const handlers = {};
  const agents = [];
  const letters = [];
  let frame;
  const element = () => {
    const classes = new Set();
    return { textContent: '', style: {},
      classList: {
        add: name => classes.add(name), remove: name => classes.delete(name),
        contains: name => classes.has(name),
      },
      setAttribute() {}, getBoundingClientRect: () => ({ left: 0, top: 0, width: 40, height: 80 }),
    };
  };
  const lines = ['AGENTS', 'TOGETHER', 'STRONG'].map((textContent, row) => ({
    textContent, style: {}, append(el) {
      const col = letters.length;
      el.getBoundingClientRect = () => ({ left: 40 + (col % 8) * 70, top: 40 + row * 110, width: 40, height: 80 });
      letters.push(el);
    },
  }));
  const hero = {
    clientWidth: 900, clientHeight: 500,
    querySelectorAll: () => lines, querySelector: () => lines[2],
    getBoundingClientRect: () => ({ left: 0, top: 0 }),
    append: el => agents.push(el), addEventListener: (name, fn) => { handlers[name] = fn; },
  };
  const document = {
    hidden: false,
    getElementById: id => id === 'hero' ? hero : { addEventListener() {} },
    createElement: element, querySelectorAll: () => [],
    addEventListener: (name, fn) => { handlers[name] = fn; },
  };
  vm.runInNewContext(read('home.js').replace(/^import .*;\n/gm, ''), {
    document, reduceMotion: reduced, decodeOnView() {}, decode() {}, glyph: () => '#',
    addEventListener() {}, setInterval() {}, setTimeout() {},
    requestAnimationFrame: fn => { frame = fn; },
  });
  return { agents, letters, document, handlers,
    frame: now => { assert.ok(frame); frame(now); },
    snapshot: () => ({
      positions: agents.flatMap(el => el.style.transform.match(/-?[\d.]+/g).map(Number)),
      weight: lines[2].style.fontWeight,
      text: letters.map(el => el.textContent).join(''),
      broken: letters.filter(el => el.classList.contains('hot')).length,
    }),
  };
}

function sameFrame(actual, expected) {
  assert.equal(actual.weight, expected.weight);
  assert.equal(actual.text, expected.text);
  assert.equal(actual.broken, expected.broken);
  actual.positions.forEach((position, i) => {
    assert.ok(Math.abs(position - expected.positions[i]) < 1e-7,
      `Cursor coordinate ${position} differs from ${expected.positions[i]}`);
  });
}

// A complete repair has the same positions, font weight, and text at shared times.
const reference = new Map();
for (const hz of [60, 30, 120, 144]) {
  const fixture = heroFixture();
  fixture.frame(0);
  fixture.handlers.click();
  assert.equal(fixture.snapshot().broken, 20);
  for (let frame = 1; frame <= hz * 6; frame++) {
    fixture.frame(frame * 1000 / hz);
    const tick = frame * 60 / hz;
    if (hz === 60) reference.set(tick, fixture.snapshot());
    else if (Number.isInteger(tick)) sameFrame(fixture.snapshot(), reference.get(tick));
  }
  assert.equal(fixture.snapshot().text, 'AGENTSTOGETHERSTRONG');
  assert.equal(fixture.snapshot().broken, 0);
}

// Display frames between ticks interpolate rather than repeating a 60 Hz pose.
const smooth = heroFixture();
smooth.frame(0);
smooth.frame(1000 / 60);
const start = smooth.snapshot();
smooth.frame(25);
const middle = smooth.snapshot();
smooth.frame(1000 / 30);
const end = smooth.snapshot();
assert.notDeepEqual(start.positions, end.positions);
middle.positions.forEach((position, i) => {
  assert.ok(Math.abs(position - (start.positions[i] + end.positions[i]) / 2) < 1e-7);
});

// A stalled frame catches up at most 100 ms, rather than simulating an entire pause.
const stalled = heroFixture();
const bounded = heroFixture();
for (const fixture of [stalled, bounded]) fixture.frame(0);
stalled.frame(60000);
bounded.frame(100);
sameFrame(stalled.snapshot(), bounded.snapshot());

// Hiding and returning preserves the fractional tick without consuming hidden time.
const paused = heroFixture();
const continuous = heroFixture();
for (const fixture of [paused, continuous]) {
  fixture.frame(0);
  fixture.frame(25);
}
paused.document.hidden = true;
paused.handlers.visibilitychange();
paused.frame(30000);
sameFrame(paused.snapshot(), continuous.snapshot());
paused.document.hidden = false;
paused.handlers.visibilitychange();
paused.frame(60000);
sameFrame(paused.snapshot(), continuous.snapshot());
paused.frame(60000 + 1000 / 120);
continuous.frame(25 + 1000 / 120);
sameFrame(paused.snapshot(), continuous.snapshot());
assert.equal(heroFixture(true).agents.length, 0);

// Text noise changes at most 60 times a second and resolves at its given duration.
for (const hz of [30, 60, 120, 144]) {
  let frame, writes = 0, text = '';
  const decode = vm.runInNewContext(read('decode.js').replace(/\bexport /g, '') + '\ndecode;', {
    matchMedia: () => ({ matches: false }), performance: { now: () => 0 },
    requestAnimationFrame: fn => { frame = fn; },
  });
  const el = { set textContent(value) { text = value; writes++; } };
  decode(el, 1000, 'Handshake');
  for (let i = 0; i <= hz; i++) {
    const next = frame;
    frame = null;
    next(i * 1000 / hz);
  }
  assert.equal(writes, Math.min(hz, 60) + 1);
  assert.equal(text, 'Handshake');
  assert.equal(frame, null);
}
const stillDecode = vm.runInNewContext(read('decode.js').replace(/\bexport /g, '') + '\ndecode;', {
  matchMedia: () => ({ matches: true }),
  requestAnimationFrame: () => assert.fail('Reduced motion must not animate'),
});
const stillText = {};
stillDecode(stillText, 1000, 'Handshake');
assert.equal(stillText.textContent, 'Handshake');
console.log('Website animation timing, interpolation, pause recovery, and reduced motion passed');
