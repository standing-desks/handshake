# 0014: Evaluate Ghostty without changing terminal ownership

Status: Proposed

## Context

Terminal text can appear softer than another macOS terminal. Handshake already
uses SwiftTerm's Metal renderer and supplies the display backing scale multiplied
by application zoom. Its UI also scales embedded native views through SwiftUI.
The screenshot alone does not establish whether glyph rasterization, font choice,
fractional positioning, or compositing causes the difference.

Ghostty is a feasible alternative engine, but two APIs have different scope:

- `libghostty-vt` supplies terminal state, input encoding, and render-state access
  for custom renderers. Replacing the parser alone does not supply Ghostty's Metal
  font renderer or establish sharper output.
- Ghostty's full embedded surface API includes rendering and process/terminal I/O.
  Its header explicitly identifies it as internal and tailored to its macOS app.
  cmux integrates a pinned Ghostty fork, demonstrating feasibility with ongoing
  integration ownership rather than a stable interchangeable view dependency.

## Proposed decision

Retain SwiftTerm for the current fixes. Evaluate Ghostty in an isolated prototype
before choosing a production migration. Compare identical text, font, colors,
point size, display scale, and zoom, including thin borders, Unicode, selection,
IME input, scrolling, and display transitions.

The prototype must demonstrate how Rust retains PTY ownership, child supervision,
byte offsets, recording, resize history, and transcript replay. A full Ghostty
surface needs an adapter or maintained fork that can consume core-owned output
and send input back through `CoreClient`; moving PTYs into Swift would violate
the current component boundary. Also verify trace/minimap navigation, keyboard
protocols, clipboard behavior, accessibility, packaging, and dependency updates.

## Consequences

Ghostty remains a credible option, with a medium-to-large integration cost. No
sharpness improvement is claimed until the prototype provides an actual visual
comparison. A smaller pixel-alignment or rasterization fix may still be sufficient.

## References

- [Ghostty architecture](https://ghostty.org/docs/about)
- [Internal embedding API](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h)
- [Virtual terminal API](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt.h)
- [Terminal I/O ownership](https://github.com/ghostty-org/ghostty/blob/main/src/termio.zig)
- [cmux Ghostty dependency](https://github.com/manaflow-ai/cmux/blob/main/.gitmodules)
- [Handshake rasterization scale](../../macOS/Handshake/Handshake/Terminal/Rendering/MetalTerminalView.swift)
- [Application zoom](../../macOS/Handshake/Handshake/Zoom/AppZoomLayout.swift)
