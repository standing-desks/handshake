libhandshakecore @VERSION@ (macOS 26+, Apple Silicon)

Include include/handshake_bridge.h and link libhandshakecore.a.
The exported API uses the handshake_ prefix.

Configure your linker for macOS system libraries: -liconv and the
Foundation framework (-framework Foundation), in addition to this archive.
The app's HandshakeCorePackage/Package.swift shows its own integration.

Follow the ownership and call rules in the header. Serialize calls to a
client, release returned buffers with handshake_buffer_release, and destroy
the client with handshake_client_destroy after all calls finish. Use one
client per application data directory.

The JSON protocol is experimental. Its command and response definitions
are in handshake-bridge/src/protocol in the matching source archive. Pin a
matching library/header release.

Source and license: https://github.com/standing-desks/handshake
Release notes: https://github.com/standing-desks/handshake/releases/tag/@RELEASE_TAG@
