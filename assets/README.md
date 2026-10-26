# Brand assets

Source art for the Handshake identity. The SVGs here are the source of truth;
do not edit, optimize, or recolor them. `SHA256SUMS` records their hashes
(`cd assets && shasum -a 256 -c SHA256SUMS`).

This folder owns shared brand sources. Component-specific assets live with
their consumers: published files in `docs/assets/`, app icons in
`macOS/Handshake/`, bundled images in the app's asset catalog, and installer
artwork in `.github/release/`. The DMG uses its separate intertwining artwork.

## Files

| File | Use |
| --- | --- |
| `handshake-square-dark.svg`, `handshake-square-light.svg` | Full-bleed squares. Reference compositions for app icons, where macOS applies its own mask. |
| `handshake-app-dark.svg`, `handshake-app-light.svg` | Rounded tiles. Shared rounded-tile placement variants. |
| `handshake-transparent.svg` | Symbol alone for lockups and quiet solid grounds. |
| `handshake-avatar-dark.svg`, `handshake-avatar-light.svg` | Circular avatars. |
| `handshake-master.svg` | Editable symbol master. |
| `handshake-identity-board.svg` | Identity board. |

## Regenerating PNGs

    swift assets/render-pngs.swift [output-folder]

Renders every placement variant at 16, 24, 32, 48, 64, 128, 256, and 512 px
into `assets/png/` (ignored by git) or the folder given. Favicons use the
16, 32, and 48 px sizes.

## Identity rules

- **Wordmark:** write Handshake as one word in title case, in system sans-serif
  at weight 600 with −0.045 em tracking.
- **Lockup:** pair the detailed symbol with the wordmark, aligned by optical
  center. At the minimum horizontal lockup, use a 48 pt symbol, a 12 pt gap,
  and a 30 pt wordmark.
- **Grounds:** ivory `#F4F1EB` and charcoal `#202326`.
- **Clear space:** keep ⅛ of the placement canvas clear on every outside edge.
- **Usage:** scale the artwork proportionally. Do not stretch it, recolor the
  hands, or add glow. Keep the clasp intact.

## Keeping shared artwork in sync

`assets/handshake-transparent.svg` is the canonical symbol. The website, app
asset catalog, and both Icon Composer documents carry byte-identical copies.
The documentation-owned `docs/generate-readme-lockup.cjs` embeds this source
in the README lockup at `docs/assets/handshake-readme-lockup.svg`.

Run `make check-assets` to verify approved source checksums, all four symbol
copies, and the generated lockup. CI runs this through `make lint-ci` and
`make check-site`. Run `make sync-assets` to refresh the component copies and
lockup from the canonical source; it refuses to alter approved source art.

## Release app icon

`macOS/Handshake/AppIcon.icon` is the macOS Icon Composer document, referenced
directly by the Xcode app target for Release. Debug selects
`macOS/Handshake/AppIconDebug.icon`. Its embedded
`Assets/handshake-transparent.svg` is byte-identical to the source SVG. The document was saved and the image layer
imported in Icon Composer 27.1; the saved schema supplies the appearance and
placement settings.

The default and dark backgrounds are both solid sRGB `#202326`. Mono uses
Icon Composer's automatic monochrome treatment of the same artwork. Layers
are unmasked; Liquid Glass effects are applied by the system.

The transparent SVG already places the symbol at 78% with an optical offset.
To match the 75% square variants, its layer scale is `25/26`
(`0.9615384615384615`) and its center-relative translation is
`[0, 0.3076923076923]` points. Equivalently, transform the imported 1024-point
canvas by `translate(19.6923076923, 20) scale(25/26)`. Composing this with the
source's transform produces `translate(45.125, 65.5) scale(0.75)`, exactly as
in both square SVGs. Do not add another 8-point optical offset.

Validation on macOS 27.0.1 / Xcode 27.1 / Icon Composer 27.1:

- The unmasked, effects-free vector composition renders pixel-identically to
  both square SVGs at 1024 px using AppKit (zero changed pixels).
- Apple `ictool` renders Default, Dark, Mono, ClearLight, ClearDark,
  TintedLight, and TintedDark with `--design-generation 26`.
- Icon Composer's editor exposes Default, Dark, and Mono. Clear and tinted
  checks use its bundled renderer; these are not additional editable layers.
- The GUI's effects-off export retains the system mask. It is not the
  unmasked geometry proof; that proof composes the document's SVG and
  placement without materials or mask.

Apple's current [Icon Composer page](https://developer.apple.com/icon-composer/)
lists macOS 26.4 or later; the installed 27.1 application's minimum is 26.6.
Generation 27 rendering adds updated materials, so use generation 26 when
reviewing the macOS 26 result. The app's deployment target is unaffected.

Recognition assessment (generation 26, automatic mono, renderer's default
purple tint): the colored hands remain distinguishable at 32 px; at 16–24 px
the clasp's fine detail merges. Clear light/dark preserve the outline and
finger shapes at larger sizes, but lose the color separation between the
hands. Tinted light remains recognizable; tinted dark is substantially
lower contrast and its clasp is difficult to read at small sizes. This is
recorded without changing the signed-off symbol. Preview sheets and geometry
diffs from this validation are under `out/icon-validation/` (not source art).

## Debug app icon

`macOS/Handshake/AppIconDebug.icon` is the release document plus one frontmost flat badge
group. Its symbol bytes, symbol group, placements, backgrounds, and platform
settings are identical to release. Removing the badge group produces a
pixel-identical render in all seven generation 26 renditions (zero changed
pixels in each 1024 px control diff).

The badge SVG is embedded in the Debug document. It uses the specified
`x=112`, `y=448`, `800×128`, `rx=32` pill, `#FFD60A` fill, and a 10-point
`#202326` stroke. DEBUG uses bold system sans-serif at 96 points with
10-point tracking, converted with CoreText to vector paths and centered by
its ink bounds. It contains no live text, bitmap, mask, filter, or baked
shadow. The badge layer has glass disabled; its group has no shadow or
translucency. Its source geometry and fills are identical in all appearances;
the system derives monochrome and tinted colors.

The 32 px comparison shows a distinct central stripe in every rendition.
The lettering has good luminance separation in the large clear/tinted
previews, but individual letters are too small to read comfortably at 32 px.
Dark tint also reduces contrast. The badge was not enlarged or redrawn;
owner approval remains part of the icon sign-off issue.

## README lockup

`docs/assets/handshake-readme-lockup.svg` embeds the approved transparent symbol in a 48 pt
placement, followed by a 12 pt gap and a 30 pt system-sans wordmark at weight 600
with −0.045 em tracking. It uses charcoal text with ivory text in dark mode.
The embedded symbol is unchanged; this derived lockup is separate from the
approved source art recorded in `SHA256SUMS`.
