# Legacy website redirects

Reviewed static source for the old `https://standing-desks.github.io/twine/`
entry points. Publish the `twine/` directory into the root of the organization
Pages repository, `standing-desks/standing-desks.github.io`, after the new
Handshake site is available. These files are not part of the Handshake project
site build, and preparing them does not deploy anything.

Keep the old **repository name `twine` unused**. Do not create a redirect
repository under that name: GitHub's repository and release URL redirects must
continue pointing to `standing-desks/handshake`. The organization Pages site
owns the old website path independently.

| Old path beneath `/twine/` | Destination beneath `/handshake/` |
| --- | --- |
| `/` | `/` |
| `documentation/` | `documentation/` |
| `documentation/guide/` | `documentation/guide/` |
| `documentation/development/` | `documentation/development/` |
| `documentation/rust/` | `documentation/rust/` |
| `documentation/rust/twine_core/` | `documentation/rust/handshake_core/` |
| `documentation/rust/twine_bridge/` | `documentation/rust/handshake_bridge/` |
| `documentation/swift/` | `documentation/swift/` |
| `documentation/swift/documentation/twine/` | `documentation/swift/documentation/handshake/` |

Each page has a canonical URL, immediate meta refresh, and a readable fallback
link. Its small inline script uses `location.replace` to preserve the original
query string and fragment without adding a back-button redirect loop. Guide,
development, and landing-page anchors keep their existing names. Rust crate
and Swift module entry points map to their new names; this is an explicit set
of documented entry points, not a general router for every generated API page.

Before publishing, run `make check-site` from this product checkout. It executes
each redirect locally for plain URLs, guide/development anchors, and query plus
fragment combinations, and checks meta/canonical/fallback targets. To inspect
the source over HTTP, serve `docs/legacy-redirects/` with a local static server.

In a separate checkout of the organization Pages repository, copy only this
folder's `twine/` directory to the publishing root, preserving its structure.
Review the diff there and use that repository's normal review/deploy process.
Do not copy this README into the public redirect tree. After deployment,
verify the old base, documentation, guide, development, Rust, and Swift entry
points and a guide URL such as `/twine/documentation/guide/#configuration`.
Do not publish until both destination site and organization-site changes have
been approved.
