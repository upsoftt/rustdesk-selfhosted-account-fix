# How the cause was found

Kept as a reference: the symptom points at the wrong layer, and several plausible
explanations turned out to be dead ends.

## Symptom

A self-hosted setup — `hbbs` + `hbbr` (open source) plus `rustdesk-api` for accounts and
the address book. Sign in, try to connect to any machine from the address book:

- the client spins for ~18 seconds, then either connects or fails with
  `Failed to secure tcp: deadline has elapsed`;
- sign out, and the same client connects in about a second.

Same behaviour on Windows, Android and iOS. On iOS downgrading the client is impossible,
so "use an older client" is not a fix.

## Dead ends

Each of these looked convincing and changed nothing:

| Hypothesis | Test | Result |
|---|---|---|
| Server key mismatch | ran `hbbs`/`hbbr` with `-k _`, then without a key at all, keys synced on every client | identical failure both ways |
| NAT / hole punching | forced `ALWAYS_USE_RELAY=Y` | identical failure |
| VPN client mangling traffic | connected to the server over a WireGuard tunnel instead of the public address | identical failure |
| Stale login token | fetched a fresh token right before connecting | identical failure |
| Address book contents | emptied the address book completely | identical failure |
| Wrong local address | removed `local-ip-addr`, reset the cached `nat_type` | identical failure |
| API server unreachable | captured HTTP on port 21114 — every request answered `200` | not the cause |

## What actually showed it

A packet capture on the server, taken while the client was "connecting":

```
IP client.62198 > server.21116: Flags [S]      # SYN
IP server.21116 > client.62198: Flags [S.]     # SYN-ACK
IP client.62198 > server.21116: Flags [.]      # ACK
                     ... 18 seconds of nothing ...
IP client.62198 > server.21116: Flags [F.]     # FIN
```

The TCP connection is established and the client sends **zero bytes**. It is not waiting
for a punch-hole reply or for the API — it is waiting for the *server* to speak first.

Reading the client source explains why:

- `src/client.rs` calls `secure_tcp()` whenever a key **and** a login token are present;
- `secure_tcp()` in `src/common.rs` starts with `conn.next()` — it reads before it writes,
  expecting `KeyExchange` with the server's box public key signed by the server key;
- `src/rendezvous_server.rs` in the open-source server never sends that message.

Hence the exact 18 seconds: it is the client's read timeout, not a network problem.

## Measurements after the patch

Same machine, same server, signed in, five runs:

```
Session start          15:01:35.787
Connection secured     15:01:35.804   (+17 ms)   <- the handshake
TCP Hole Punched       15:01:35.847
connection established 15:01:35.904   (+117 ms total)
```

Before the patch the same sequence took 18–19 seconds or ended in
`Failed to secure tcp`.
