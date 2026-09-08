# RustDesk self-hosted server: fix for signed-in clients

Patch for the open-source [rustdesk-server](https://github.com/rustdesk/rustdesk-server)
(`hbbs`) that makes **account login work on a self-hosted setup**.

## The problem

On a self-hosted server, a RustDesk client **that is signed in to an account** cannot
connect. Depending on client version and timing you get either

```
Failed to secure tcp: deadline has elapsed: Please try later
```

or an ~18 second stall before every single connection. Sign out — and the very same
client connects in about a second. Reported upstream, unfixed as of September 2026:

- [rustdesk/rustdesk#12875](https://github.com/rustdesk/rustdesk/issues/12875)
- [lejianwen/rustdesk-api#482](https://github.com/lejianwen/rustdesk-api/issues/482)

## The cause

Since 1.4.1 a signed-in client encrypts its channel to the rendezvous server. In
`src/client.rs` the client calls `secure_tcp()` whenever **both** a key and a login token
are present:

```rust
if !key.is_empty() && (!token.is_empty() || !switch_code.is_empty()) {
    secure_tcp(&mut socket, &key).await
        .map_err(|e| anyhow!("Failed to secure tcp: {}", e))?;
}
```

`secure_tcp()` then **waits for the server to speak first** — it expects a `KeyExchange`
message carrying the server's box public key, signed with the server key, and only then
replies with a symmetric key sealed for that public key.

The open-source `hbbs` never sends it. `handle_listener_inner()` splits the socket and
goes straight to reading:

```rust
let (a, mut b) = Framed::new(stream, BytesCodec::new()).split();
sink = Some(Sink::TcpStream(a));
while let Ok(Some(Ok(bytes))) = timeout(30_000, b.next()).await { ... }
```

Both sides wait for each other until the client's read timeout expires. A packet capture
on the server shows it plainly: the TCP connection is established, and then the client
sends **zero bytes** for 18 seconds.

The handshake exists in RustDesk Server Pro; in the open-source build it is absent.

## The fix

`patches/0001-secure-handshake-for-signed-in-clients.patch` adds to
`src/rendezvous_server.rs`:

- **`secure_handshake()`** — on a plain TCP connection, when the server was started with a
  key (`-k`), it generates a `box_` keypair, signs the public key with the server's
  signing key, sends it as `KeyExchange`, reads back the client's public key plus the
  sealed symmetric key, and opens it.
- **`Sink::SecureTcpStream`** — a sink variant that encrypts outgoing messages with that
  symmetric key via `Encrypt` from `hbb_common`; the read loop decrypts incoming ones.

Clients that do not take part in the exchange are unaffected: whatever they send instead
of `KeyExchange` is passed through to the normal handler, so anonymous clients and older
versions keep working exactly as before.

### Result

Measured on the same machine, same server, same account:

| | stock `hbbs` | patched `hbbs` |
|---|---|---|
| connect while signed in | 18–19 s, often fails | **6–41 ms** |
| connect while signed out | ~1 s | ~1 s |

The client log now prints `Connection secured` right after the TCP connect.

## Build

Any Linux box with Rust works. `build/build-hbbs.sh` is the script used here; it is
deliberately frugal because it runs on a NAS that also serves databases:

```sh
export CARGO_BUILD_JOBS=1
export CARGO_PROFILE_RELEASE_LTO=false      # peak RSS during linking
ulimit -v 3600000                            # 2 GB is not enough: linker dies with ENOMEM
git clone --depth 1 --recursive https://github.com/rustdesk/rustdesk-server.git
cd rustdesk-server
git apply ../patches/0001-secure-handshake-for-signed-in-clients.patch
cargo build --release --bin hbbs
```

Docker one-liner:

```sh
docker run --rm -v "$PWD:/work" -w /work --cpus 1.5 --memory 2g \
  rust:1.88-bookworm bash -c "bash build/build-hbbs.sh"
```

## Deploy

```sh
cp /opt/rustdesk-server/hbbs /opt/rustdesk-server/hbbs.stock   # keep a way back
systemctl stop rustdesk-hbbs
cp hbbs /opt/rustdesk-server/hbbs
systemctl start rustdesk-hbbs
```

Rollback is `cp hbbs.stock hbbs && systemctl restart rustdesk-hbbs`.

`hbbs` must run **with a key** (`-k _` uses the generated `id_ed25519`), and every client
must carry that public key — the handshake only happens when a key is configured on both
ends.

## Full stack this was built for

- `hbbs` + `hbbr` — the open-source server, patched as above;
- [rustdesk-api](https://github.com/lejianwen/rustdesk-api) on port 21114 — accounts,
  login and a shared address book, the parts RustDesk sells as Server Pro;
- Windows, Android and iOS clients 1.4.9, all signed in to the same account and seeing
  each other in one address book.

Ports: 21114 (API), 21115–21117 (`hbbs`/`hbbr`), 21118–21119 (websocket).

## Your own domain

Point a subdomain at the box — `remote.example.com` — and put it in the clients instead of
an IP:

```toml
custom-rendezvous-server = 'remote.example.com'
relay-server = 'remote.example.com'
api-server = 'https://remote.example.com'
```

The API server (port 21114) is plain HTTP by default, so put nginx in front of it with a
certificate if the login page is reachable from the internet — accounts and tokens should
not travel in the clear. `hbbs`/`hbbr` traffic is encrypted on its own and needs no proxy.

Accounts are created on your server, in the API server's admin panel (`/_admin/`). Nobody
signs in through rustdesk.com, no address book leaves the machine, and there is no account
on someone else's infrastructure to lose.

Client-side configuration, logs and the workarounds tried before this patch are collected
in [rustdesk-selfhosted-client-notes](https://github.com/upsoftt/rustdesk-selfhosted-client-notes).

## Notes

- **A server upgrade drops the patch.** After updating `rustdesk-server`, re-apply it.
- There is a second workaround that needs no patch: turn on `allow-websocket = 'Y'` in the
  client config. A websocket connection skips `secure_tcp()` entirely (see `use_ws()` in
  `hbb_common`), so signed-in clients work — but the websocket connection proved less
  stable here and interfered with the service registering itself.
- Not affiliated with or endorsed by RustDesk. Their server is AGPL-3.0; this patch is
  published under the same license.
