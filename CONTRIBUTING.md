<!-- Adapted from CNCF project-template/CONTRIBUTING.md at
https://github.com/cncf/project-template/blob/e66ba44f724d00f66c84932593c5a229fee3564b/CONTRIBUTING.md
Licensed under Apache-2.0; see docs/licenses/cncf-project-template-LICENSE.txt.
Changes: select the welcome, Find an Issue, and DCO sections; omit template
instructions and the unfinished fallback paragraph; link Handshake's existing labels
and development instructions; link the canonical DCO and signing documentation. -->

# Contributing Guide

Welcome! We are glad that you want to contribute to Handshake! 💖

As you get started, you are in the best position to give us feedback on areas of
our project that we need help with including:

* Problems found during setting up a new developer environment
* Gaps in our Quickstart Guide or documentation
* Bugs in our automation scripts

If anything doesn't make sense, or doesn't work when you run it, please open a
bug report and let us know!

## Find an Issue

We have good first issues for new contributors and help wanted issues suitable
for any contributor. [good first issue](https://github.com/standing-desks/handshake/labels/good%20first%20issue) has extra information to
help you make your first contribution. [help wanted](https://github.com/standing-desks/handshake/labels/help%20wanted) are issues
suitable for someone who isn't a core maintainer and is good to move onto after
your first pull request.

Once you see an issue that you'd like to work on, please post a comment saying
that you want to work on it. Something like "I want to work on this" is fine.

## Development Environment Setup

- [Build from source](README.md#build-from-source)
- [Check your changes](README.md#check-your-changes)
- [Development guide](https://standing-desks.github.io/handshake/documentation/development/)
- [Repository conventions](AGENTS.md)

## Brand and Interface Design

Handshake's visual identity is limited to the name, the symbol, and the wordmark
and lockup typography. Use these identity rules:

- Write the name as one word: **Handshake**.
- Set the wordmark in system sans-serif at weight 600 with −0.045 em tracking.
  Place it beside the symbol, aligned by optical center.
- The minimum horizontal lockup uses a 48 pt symbol, a 12 pt gap, and a 30 pt
  wordmark.
- Keep ⅛ of the placement canvas clear around the symbol.
- Never stretch, recolor, or add glow to the symbol.

Interface design follows Apple's Human Interface Guidelines and the repository's
conventions. The identity rules do not prescribe an interface palette or brass
accent, role colors or glyphs, status labels, components or layouts, motion or
geometry values, interface copy or capitalization, or a product mockup. Those
choices are outside the adopted identity scope.

## Naming and Compatibility

Use **Handshake** for the product. The component names are
`handshake-core` (Rust application library), `handshake-bridge` (C ABI adapter),
`HandshakeCore` (Swift core package), and `HandshakeSyntax` (Swift syntax package).
Use the domain vocabulary in [CONTEXT.md](CONTEXT.md) and the architecture rules
in [AGENTS.md](AGENTS.md). The macOS app lives in `macOS/Handshake/`; the Swift
packages live in `macOS/HandshakeCorePackage/` and
`macOS/HandshakeSyntaxPackage/`.

For this release, preserve the existing macOS bundle IDs, including
`com.twineproject.Twine` and `com.twineproject.Twine.development`, and the
`com.twineproject.Twine` log subsystem. These Twine names are intentional
compatibility identifiers that maintain application identity and log continuity.

Use `~/.config/handshake/config.toml` by default, adopting the existing
`~/.config/twine/` tree when the Handshake root is not established. Keep legacy
config and theme inputs readable and retain the source. For supported
environment-variable inputs, read
`HANDSHAKE_*` first and use the corresponding `TWINE_*` input as a fallback.
Preserve historical releases and user content; do not rewrite either to apply
the new name.

Add an alias layer only when a consumer need is recorded in the naming and
inputs inventory. Retained compatibility names are specific contracts, not a
reason to introduce aliases for every renamed symbol or component.

## Sign Your Commits

Licensing is important to open source projects. It provides some assurances that
the software will continue to be available based under the terms that the
author(s) desired. We require that contributors sign off on commits submitted to
our project's repositories. The [Developer Certificate of Origin
(DCO)](https://probot.github.io/apps/dco/) is a way to certify that you wrote and
have the right to contribute the code you are submitting to the project.

You sign-off by adding the following to your commit messages. Your sign-off must
match the git user and email associated with the commit.

    This is my commit message

    Signed-off-by: Your Name <your.name@example.com>

Git has a `-s` command line option to do this automatically:

    git commit -s -m 'This is my commit message'

If you forgot to do this and have not yet pushed your changes to the remote
repository, you can amend your commit with the sign-off by running

    git commit --amend -s

[Developer Certificate of Origin 1.1](DCO) · [DCO bot documentation](https://github.com/dcoapp/app#how-it-works)
