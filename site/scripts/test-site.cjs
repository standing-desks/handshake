// Exercise the shipped browser script without a browser or desktop access.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const site = path.join(__dirname, '..');
const read = name => fs.readFileSync(path.join(site, name), 'utf8');
const source = read('src/download.js');
const html = read('index.html');
const command = 'brew install --cask standing-desks/tap/handshake';
const copyValues = [...html.matchAll(/data-copy="([^"]+)"/g)].map(match => match[1]);
assert.deepEqual(copyValues, [command, command]);

// Every workflow type shows a real screenshot from public/.
const shots = [...html.matchAll(/data-shot="([^"]+)"/g)].map(match => match[1]);
assert.equal(shots.length, 5);
const missingShots = shots.filter(shot => !fs.existsSync(path.join(site, 'public', shot)));
assert.deepEqual(missingShots, [], `Add the missing workflow screenshots to site/public/: ${missingShots.join(', ')}`);

function fixture(assets, options = {}) {
  const timers = [];
  const assigned = [];
  const copied = [];
  const selected = [];
  const requests = [];
  const feedback = new Map();
  function button(dataset) {
    return { dataset, attributes: {}, handlers: {}, label: { textContent: 'Copy' },
      code: { textContent: command },
      addEventListener(name, handler) { this.handlers[name] = handler; },
      setAttribute(name, value) { this.attributes[name] = value; },
      removeAttribute(name) { delete this.attributes[name]; },
      querySelector() { return this.label; },
    };
  }
  const downloads = ['hero-download-status', 'start-download-status'].map(id => {
    feedback.set(id, { hidden: true, message: {}, fallback: { hidden: true },
      querySelector(name) { return name === 'span' ? this.message : this.fallback; } });
    return button({ macosDownload: id });
  });
  const copies = copyValues.map(value => {
    const copy = button({ copy: value });
    copy.parentElement = { querySelector: () => copy.code };
    return copy;
  });
  vm.runInNewContext(source, {
    document: {
      querySelectorAll: selector => selector === '[data-macos-download]' ? downloads : copies,
      getElementById: id => feedback.get(id),
    },
    window: { location: { assign: url => assigned.push(url) } },
    fetch: async (url, init) => {
      requests.push({ url, init });
      if (options.networkError) throw Error('Offline');
      return { ok: !options.httpError, json: async () => ({ assets }) };
    },
    navigator: { clipboard: { writeText: async value => {
      if (options.clipboardDenied) throw Error('Denied');
      copied.push(value);
    } } },
    getSelection: () => ({ selectAllChildren: node => selected.push(node.textContent) }),
    setTimeout: (callback, delay) => { timers.push({ callback, delay }); return timers.length; },
    clearTimeout: () => {}, AbortController,
  });
  return { downloads, copies, feedback, assigned, copied, selected, requests, timers };
}
const asset = (product, state = 'uploaded', arch = 'arm64') => ({
  name: `${product}-0.4.0-macos-${arch}.dmg`, state,
  browser_download_url: `https://github.com/standing-desks/handshake/releases/download/v0.4.0/${product}.dmg`,
});
async function click(button, overrides = {}) {
  const event = { button: 0, preventDefault() { this.prevented = true; }, ...overrides };
  await button.handlers.click(event);
  return event;
}
(async () => {
  for (const assets of [[asset('Twine')], [asset('Handshake')], [asset('Twine'), asset('Handshake')],
    [asset('Handshake', 'uploaded', 'universal')]]) {
    const page = fixture(assets);
    await click(page.downloads[0]);
    const expected = assets.find(item => item.name.startsWith('Handshake-')) ?? assets[0];
    assert.deepEqual(page.assigned, [expected.browser_download_url]);
    assert.equal(page.requests[0].url, 'https://api.github.com/repos/standing-desks/handshake/releases/latest');
    assert.equal(page.downloads[1].href, expected.browser_download_url);
    assert.match(page.feedback.get('hero-download-status').message.textContent,
      expected.name.startsWith('Handshake-') ? /drag Handshake/ : /drag Twine/);
    assert.deepEqual(page.downloads[0].attributes, {});
  }
  for (const [assets, options] of [[[], {}], [[asset('Handshake', 'new')], {}],
    [[asset('Handshake', 'uploaded', 'x86_64')], {}], [undefined, {}], [[], { httpError: true }],
    [[], { networkError: true }]]) {
    const page = fixture(assets, options);
    await click(page.downloads[0]);
    assert.deepEqual(page.assigned, []);
    assert.equal(page.feedback.get('hero-download-status').fallback.hidden, false);
    assert.deepEqual(page.downloads[0].attributes, {});
  }
  const modified = fixture([asset('Handshake')]);
  assert.equal((await click(modified.downloads[0], { metaKey: true })).prevented, undefined);
  assert.deepEqual(modified.requests, []);
  for (const clipboardDenied of [false, true]) {
    const page = fixture([], { clipboardDenied });
    for (const copy of page.copies) {
      await click(copy);
      assert.equal(copy.label.textContent, clipboardDenied ? 'Press ⌘C' : 'Copied');
    }
    assert.deepEqual(clipboardDenied ? page.selected : page.copied, [command, command]);
    page.timers.filter(timer => timer.delay === 2000).forEach(timer => timer.callback());
    assert.equal(page.copies[0].label.textContent, 'Copy');
  }
  const redirects = new Map([
    ['', ''], ['documentation/', 'documentation/'],
    ['documentation/guide/', 'documentation/guide/'],
    ['documentation/development/', 'documentation/development/'],
    ['documentation/rust/', 'documentation/rust/'],
    ['documentation/rust/twine_core/', 'documentation/rust/handshake_core/'],
    ['documentation/rust/twine_bridge/', 'documentation/rust/handshake_bridge/'],
    ['documentation/swift/', 'documentation/swift/'],
    ['documentation/swift/documentation/twine/', 'documentation/swift/documentation/handshake/'],
  ]);
  for (const [oldPath, newPath] of redirects) {
    const page = read(`legacy-redirects/twine/${oldPath}index.html`);
    const target = `https://standing-desks.github.io/handshake/${newPath}`;
    assert.ok(page.includes(`rel="canonical" href="${target}"`));
    assert.ok(page.includes(`content="0; url=${target}"`));
    assert.ok(page.includes(`<a href="${target}">`));
    const script = page.match(/<script>([\s\S]*?)<\/script>/)[1];
    for (const [search, hash] of [['', ''], ['', '#configuration'], ['?from=legacy', '#install']]) {
      let destination;
      vm.runInNewContext(script, { location: { search, hash, replace: url => { destination = url; } } });
      assert.equal(destination, target + search + hash);
    }
  }
  console.log('Website downloads, copy controls, workflow screenshots, and nine legacy redirect entry points passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
