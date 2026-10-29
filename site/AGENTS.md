# Website

The GitHub Pages site: the home page, the documentation index, and the user and development guides. It is plain HTML, CSS, and JavaScript as native ES modules, built with Vite. Each page is its own `index.html`; register new pages in `rollupOptions.input` in `vite.config.js`.

## Commands

Run these from the repository root:

- `make serve-site`: local server with live reload.
- `make check-site`: run `scripts/test-site.cjs`, which checks downloads, copy controls, workflow screenshots, and legacy redirects without a browser.
- `make build-site`: the full published build. It also builds the Rust and Swift API references into `documentation/rust/` and `documentation/swift/`, so it needs Xcode. For the site alone, run `npm run build` in `site/` and open `dist/`.

Keep dependency changes in both `package.json` and `package-lock.json`.

## Design

- The page is a running machine, not a poster: one live spectacle per screen in a quiet frame of hairline rules, monospace labels, and tabular numbers. On the home page the spectacle is the slogan, **Agents Together Strong**, which the visitor breaks and the role cursors repair.
- Colors come from the Handshake symbol and live as tokens at the top of `src/style.css`: ivory and charcoal grounds, brass for the human hand (deep brass for text on ivory), and the prism gradient for the machine hand. Role colors are fixed: implementer Codex blue, coordinator charcoal, reviewer Claude orange, resting in that order.
- Set display type and labels in Martian Mono, and running prose in the system sans.
- Headings and numbers decode in through `src/decode.js`. Mark plain-text elements with `data-decode`; elements with child markup keep their markup and skip the effect.
- Follow the identity rules in [CONTRIBUTING.md](../CONTRIBUTING.md#brand-and-interface-design) for the symbol and wordmark, including the 48 pt, 12 pt, 30 pt minimum lockup.
- Every animation has a still state under `prefers-reduced-motion`, and the page reads completely before any script runs.

## Content

- Write for people using Handshake, with the terms in [CONTEXT.md](../CONTEXT.md). Development detail belongs in the development guide.
- Check every stated fact against the source when it changes:
  - Harnesses come from `handshake-core/src/harness.rs`. The home page names them in the harness section, counts them in the stats row, and cycles them in `HARNESSES` in `src/home.js`.
  - Built-in workflow types and their role counts come from `handshake-core/workflows/`.
  - Browser facts come from [the browser-control decision](../docs/adr/0012-control-the-embedded-browser-through-core.md) and `handshake-core/src/config/experimental.rs`. Label agent browser control as a beta while it stays under Experimental.
  - The release number comes from the workspace version in `Cargo.toml`. Write `%HANDSHAKE_VERSION%` in HTML and the build fills it in.
- Each workflow-type row shows a real app screenshot named by its `data-shot`, in `public/screens/`. Capture them all at 2744 × 1822, as window captures with their shadow, from the same disposable demo folder, with no personal names, paths, or accounts in view, and describe each one in the row's `data-alt`. `make check-site` fails while any is missing. `screens/coordinator.png` is also the social preview image.
- The header and footer markup is repeated on every page. Change all four pages together.
- The guides are hand-edited HTML. Keep heading IDs stable: the legacy redirects and external links point at them.

## Code

- Use page-relative links so the build works under the `/handshake/` Pages path. Reference files in `public/` with a leading `/` in HTML; Vite rewrites them relative to the page.
- `make check-site` runs `src/download.js` in a Node VM, so it stays a plain script with no imports or exports. The home page keeps exactly two copy buttons and two download links, with the feedback IDs the test names.
- `public/documentation/rust/index.html` redirects to the `handshake_core` reference, which the build copies beside it.
- `legacy-redirects/` holds the old Twine URLs and is published separately; it is not part of this build. Read its README before changing it.

## Validation

After changing presentation or interaction, check the affected pages in a browser at desktop and phone widths, with reduced motion on and off, and step through the workflow rows by keyboard. Check for clipped text, horizontal scrolling, and console errors.
