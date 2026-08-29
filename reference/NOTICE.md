# Vendored reference sources

These are **not** compiled into spoticyclint. They are the sources the Odin
protocol code was ported from, kept here so the port can be audited line by
line.

- `librespot/` — from [librespot](https://github.com/librespot-org/librespot)
  v0.8.0, MIT licensed. The Spotify access-point handshake (`handshake.rs`),
  the Shannon packet framing (`codec.rs`), the login exchange (`mod.rs`), the
  Diffie–Hellman parameters (`diffie_hellman.rs`) and the two protobuf schemas
  actually used.
- `shannon/` — the [`shannon`](https://crates.io/crates/shannon) crate v0.2.0,
  a Rust port of the Shannon stream cipher reference implementation by Hawkes
  and Rose. `src/shannon.odin` is a direct translation of this file.

Ported files carry a comment pointing back here.
