# 0014: Retain SwiftTerm and align terminal glyphs to device pixels

Status: Accepted

## Context

Terminal text can appear softer than another macOS terminal. Handshake already
uses SwiftTerm's Metal renderer and supplies the display backing scale multiplied
by application zoom. Its UI also scales embedded native views through SwiftUI.
Font choice, stroke smoothing, fractional positioning, and host compositing can
each affect the comparison. SwiftTerm's pinned Metal renderer places integer
glyph bitmaps at fractional origins and then samples them with linear filtering.
Upstream PR #775 fixes that defect, including the block cursor and CoreGraphics
fallback. The upstream revision also includes a 2.0 API migration that removes
the mutable terminal access used by Handshake's current integration.

Ghostty is a feasible alternative engine, but two APIs have different scope:

- `libghostty-vt` supplies terminal state, input encoding, and render-state access
  for custom renderers. Replacing the parser alone does not supply Ghostty's Metal
  font renderer or establish sharper output.
- Ghostty's full embedded surface API includes rendering and process/terminal I/O.
  Its header explicitly identifies it as internal and tailored to its macOS app.
  cmux integrates a pinned Ghostty fork, demonstrating feasibility with ongoing
  integration ownership rather than a stable interchangeable view dependency.

## Decision

Retain the pinned SwiftTerm 1.19.0 API and backport only upstream PR #775's
glyph-origin alignment. Round origins in final device-pixel space after drawing
transforms, before clipping, and translate each quad without changing its size.
Keep cursor and ordinary text on the same grid; leave shaping, glyph fitting,
cell geometry, colors, and decorations unchanged.

Also resolve the Metal block cursor's character through the terminal's grapheme
store, as ordinary rows and the CoreGraphics caret already do. Interpreting an
interned grapheme identifier as a Unicode scalar can replace emoji or combined
characters with a space under the cursor. This one-line correction is recorded
separately from the upstream backport in the patch's provenance.

Apply the checked-in patch through the root Makefile after dependency resolution
for both Debug and Release. Verify the exact dependency revision, accept an
already-applied patch, and fail on conflicting source changes rather than resetting
them. Include the patch in the dependency cache key. Remove the backport when a
reviewed dependency update includes the fix; do not silently adopt SwiftTerm 2.0.

Keep configured fonts, stroke smoothing, and antialiasing unchanged. Compare
identical fonts, point sizes, colors, display
scale, and zoom when assessing weight or sharpness. Exercise fractional placement,
thin borders, Unicode, selection, scrolling, and display transitions. A native
pixel regression must fail before the backport and pass afterward.
Debug-only internal access exposes the renderer's actual draw data to tests;
assert device-pixel origins and text/cursor texture-coordinate agreement for
ordinary text, doubled rows, and color emoji without relying on GPU readback timing.

Evaluate Ghostty in an isolated prototype only if the focused rendering fixes
remain insufficient. A renderer migration is not approved by this decision.

The prototype must demonstrate how Rust retains PTY ownership, child supervision,
byte offsets, recording, resize history, and transcript replay. A full Ghostty
surface needs an adapter or maintained fork that can consume core-owned output
and send input back through `CoreClient`; moving PTYs into Swift would violate
the current component boundary. Also verify trace/minimap navigation, keyboard
protocols, clipboard behavior, accessibility, packaging, and dependency updates.

## Consequences

The rendering correction is small, but carrying a dependency patch creates an
explicit maintenance obligation. Tests and native comparisons cover the changed
paths without claiming every display or compositor configuration is equivalent.
Ghostty remains a credible option with a medium-to-large integration cost; no
Ghostty sharpness improvement is claimed without a native visual comparison.

## References

- [Upstream glyph-alignment fix](https://github.com/migueldeicaza/SwiftTerm/pull/775)
- [SwiftTerm 2.0 migration](https://github.com/migueldeicaza/SwiftTerm/blob/5d6b3bf2b3667d03f753aa9f73b05175fcc4d357/Sources/SwiftTerm/Documentation.docc/MigratingFrom1To2.md)
- [Pinned backport](../../macOS/Handshake/Scripts/SwiftTerm/device-pixel-glyph-origins.patch)
- [Ghostty architecture](https://ghostty.org/docs/about)
- [Internal embedding API](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h)
- [Virtual terminal API](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt.h)
- [Terminal I/O ownership](https://github.com/ghostty-org/ghostty/blob/main/src/termio.zig)
- [cmux Ghostty dependency](https://github.com/manaflow-ai/cmux/blob/main/.gitmodules)
- [Handshake rasterization scale](../../macOS/Handshake/Handshake/Terminal/Rendering/MetalTerminalView.swift)
- [Application zoom](../../macOS/Handshake/Handshake/Zoom/AppZoomLayout.swift)
