// Check by default; use make sync-assets to refresh derived component assets.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const readmeLockup = require('../docs/generate-readme-lockup.cjs');
const root = path.resolve(__dirname, '..');
const write = process.argv.includes('--write');
const read = name => fs.readFileSync(path.join(root, name));

// Approved source art must remain unchanged, including during synchronization.
for (const line of read('assets/SHA256SUMS').toString().trim().split('\n')) {
  const [, expected, name] = line.match(/^([a-f0-9]{64})\s+(.+)$/);
  const actual = crypto.createHash('sha256').update(read(`assets/${name}`)).digest('hex');
  assert.equal(actual, expected, `Approved source art changed: assets/${name}`);
}

const symbol = read('assets/handshake-transparent.svg');
const copies = [
  'docs/assets/handshake-transparent.svg',
  'macOS/Handshake/Handshake/Assets.xcassets/HandshakeLogo.imageset/handshake-transparent.svg',
  'macOS/Handshake/AppIcon.icon/Assets/handshake-transparent.svg',
  'macOS/Handshake/AppIconDebug.icon/Assets/handshake-transparent.svg',
].map(name => [name, symbol]);
copies.push(['docs/assets/handshake-readme-lockup.svg', Buffer.from(readmeLockup(symbol.toString()))]);

for (const [name, expected] of copies) {
  if (write) fs.writeFileSync(path.join(root, name), expected);
  assert.ok(read(name).equals(expected), `${name} differs from its shared source; run make sync-assets`);
}
console.log(`Brand source checksums and ${copies.length} component assets ${write ? 'synchronized' : 'verified'}`);
