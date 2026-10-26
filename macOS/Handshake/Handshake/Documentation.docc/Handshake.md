# ``Handshake``

A native macOS workspace for coordinating coding agents.

## Overview

Handshake's macOS front end presents folder windows, sessions, workflows,
terminals, files, and traces. Application state and orchestration live in the
`handshake-core` library. ``CoreClient`` is the Swift entry point for commands and state
published across the C ABI.

This reference includes internal app symbols. It describes the implementation
for contributors; these symbols are not a stable library API.

For installation and usage, see the [Handshake user guide](https://standing-desks.github.io/handshake/documentation/guide/).
For the reusable application library and its C interface, see the
[handshake-core reference](https://standing-desks.github.io/handshake/documentation/rust/).

## Topics

### Application and folder windows

- ``HandshakeApp``
- ``FolderWindowRoot``
- ``FolderView``

### Core communication

- ``CoreClient``
- ``CoreTransport``
- ``CoreWorker``

### Workflows and terminals

- ``WorkflowWorkspace``
- ``WorkflowDesigner``
- ``TerminalController``
