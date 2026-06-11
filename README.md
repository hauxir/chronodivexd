# chronodivexd — an Elixir reimplementation of the Chrono Divide backend

This is a from-scratch, self-contained server that speaks the protocols the
Chrono Divide web client uses, so you can run the **signup → login → custom-game
lobby → join → play** flow entirely against your own machine, with no
`chronodivide.com` backends required.

It covers signup, login, the custom-game lobby, joining, in-game play, and
**unranked quick match (1v1 + random 2v2)**. See
[Relation to the original server](#relation-to-the-original-server) for what is
faithful and what is intentionally omitted (ladder/ranked, rating-based
matchmaking, the party system).

> The genuine lobby server is a C++ PvPGN fork
> (`github.com/chronodivide/pvpgn-server`, `chronodivide` branch). This Elixir
> server implements the same Westwood-Online wire protocol and additionally
> covers the parts PvPGN doesn't ship: native WebSocket transport, the in-game
> **gserv** relay, and HTTP registration. PvPGN is a useful cross-reference for
> lobby behavior.

## What it implements

One Bandit HTTP listener on **port 4000** with three roles:

| Endpoint | Protocol | Purpose |
|----------|----------|---------|
| `POST /register` | HTTP+JSON | Account signup (`{user,pass,locale}` → `{}` or `{error}`) |
| `GET /` (WS) | WOL (IRC-like text) | Login, channels, the `#Lob 45 0` lobby, game create/list/join, chat, options, start |
| `GET /gserv` (WS) | gserv (text + binary) | Per-match relay: instance create/join, map transfer, load sync, lockstep action relay |

Accounts are persisted in **SQLite** (`priv/chronodivexd.db`) with PBKDF2-HMAC-SHA256
hashed passwords.

## Architecture

- `Chronodivexd.Router` — Plug router: `/register` (+ CORS) and the two WS upgrades.
- `Chronodivexd.Accounts` / `Chronodivexd.Account` — Ecto + SQLite, hashing/verification.
- `Chronodivexd.Wol.Hub` — one GenServer holding all lobby state (sessions, channels,
  membership/ops/topic/`+l`, game rooms); broadcasts by `send`-ing member pids.
- `Chronodivexd.Wol.Conn` — a `WebSock` handler per lobby socket; parses commands,
  drives the Hub, formats IRC lines.
- `Chronodivexd.Gserv.Registry` — gameId → instance pid.
- `Chronodivexd.Gserv.Instance` — one GenServer per match: opts, transferred map,
  per-player load/active state, the start gate (`NET_RATE` + `GAME_START`), and
  the per-turn binary action aggregation/relay.
- `Chronodivexd.Gserv.Conn` — a `WebSock` handler per gserv socket.
- `Chronodivexd.Gserv.Opts` — parses the opts string to assign each player its
  `playerId` (= its index in the human-player list, matching the engine).
- `Chronodivexd.Wol.MatchBot` — the quick-match "matchbot": handles the
  `ListQueues`/`Match`/`Stats` whispers, queues players, pairs two for 1v1, and
  launches the game (see Quick match below).

## Quick match (1v1 unranked)

The client's Quick Game screen whispers a virtual user **`matchbot`** to queue.
On a pair, neither client hosts — both `joinGame` with map transfer off — so the
**server** authors the game-options string and creates the gserv instance, then
pushes `STARTG` to both.

We have no map database, so the options string is built from a **template**
(for the correct encoding + settings) plus a configurable **map pool** (for map
variety) — the same shape the original PvPGN server uses (`conf/bnmaps.conf` +
server-authored game options):

- **Template** — supplies speed/credits/mode/etc. The matchbot auto-captures one
  from the first custom game played with an **official map** (a 2-slot map seeds
  1v1; a 4+-slot map seeds both), or set `QM_TEMPLATE` to a known-good options
  string to enable from boot. Matched players are swapped in (teams 0/1 for 1v1,
  0,0/1,1 for 2v2; random colors/starts the engine resolves deterministically
  from the shared start timestamp).
- **Map pool** — point `QM_MAPS_FILE` at a `bnmaps`-style file
  (`<queue> <map-filename> [maxslots]`, see `priv/qm_maps.conf.example`). The
  matchbot picks a random map from it per game and swaps it into the options.
  Without it, the matchbot reuses the template's own map.

A queue is offered (`ListQueues`) only once it has a usable template (and pool,
if configured); until then the client shows "mode unavailable" gracefully.

## Relation to the original server

The genuine backend is a C++ **PvPGN** fork
(`github.com/chronodivide/pvpgn-server`, branch `chronodivide`) — the
long-running Battle.net / Westwood-Online emulator. chronodivexd implements the
same WOL wire protocol; the fork's commit history corroborates the quirks it
handles ("return ping and operator status in join reply", "return ping in
joingame/game list/names reply", "honor game channel mode +l", "configurable wol
account auto create").

**Faithful to the original**

- WOL lobby: login, MOTD, channels, the `#Lob` lobby, game create/list/join,
  chat, game-option relay, `startg`.
- Quick match: the same `anongame` shape — a configured **map pool**
  (`conf/bnmaps.conf` there, `QM_MAPS_FILE` here) plus **server-authored game
  options** with a map picked per game. The original also loads the map locally
  (it hardcodes a nominal map size and no digest), matching our no-transfer path.

**Beyond the original (not in the PvPGN fork)** — these the fork doesn't ship;
the real service handles them elsewhere, and we implement them here:

- Native **WebSocket** transport (PvPGN is plain TCP; the real deployment needs a
  WS↔TCP bridge in front of it).
- The in-game **gserv** relay (binary lockstep action relay, map transfer, load
  sync, `NET_RATE`/`GAME_START`).
- HTTP **`/register`** (PvPGN auto-creates the WOL account on first login).

**Intentionally omitted** (relative to the original)

- **Ladder / ranked play** and results reporting (`wladder` / `wgameres` /
  leaderboard) — out of scope.
- **Rating-based matchmaking** — the original pairs by ladder-points difference
  ("Match players based on ladder points diff"); we pair FIFO / randomly.
- The **party system** (the `PARTY_*` codes — inviting a friend to *guarantee*
  being teammates). Our 2v2 is **random** only (solo-queue → random teams).
- Larger team queues (the original's map config also lists 3v3/4v4); we do
  1v1 and 2v2.
- Anti-spam gating present in the fork ("require minimum account age / games
  played before sending messages") and persistent in-channel **bans** (we relay
  `KICK` but don't persist bans).

## Run

```sh
cd chronodivexd
mix deps.get
mix ecto.create && mix ecto.migrate     # one-time: create priv/chronodivexd.db
mix run --no-halt                         # listens on http://localhost:4000
```

Environment overrides: `PORT`, `DATABASE_PATH`, and `GSERV_HOST` / `GSERV_SCHEME`
(host:port and `ws`/`wss` advertised to clients in `STARTG`). gserv runs on this
same listener, so by default the URL is **auto-derived from the Host the client
reached us on** (honoring `X-Forwarded-Host`/`-Proto`) — no config needed for
local/LAN play. Only set `GSERV_HOST`/`GSERV_SCHEME` when clients must reach
gserv at a fixed public name that differs from their WOL `Host` header.

Point a client at it by editing its `servers.ini` to add a region whose
`wolUrl` is this server's WebSocket URL and `apiRegUrl` its `/register` endpoint
(omit `wladderUrl`/`wgameresUrl`/`mapTransferUrl` — ladder is off and gserv
handles map transfer):

```ini
[local]
label="Local Server"
available=yes
gameVersion=0.82
wolUrl="ws://localhost:4000/"
apiRegUrl="http://localhost:4000/register"
```

Then run the client and pick that region. Behind a TLS reverse proxy, use
`wss://`/`https://`; if the proxy sets `X-Forwarded-Host`/`X-Forwarded-Proto`
the gserv URL follows automatically, otherwise pin it with `GSERV_HOST=<host>`
+ `GSERV_SCHEME=wss`.

> Actually *playing* a match still requires your own Red Alert 2 + Yuri's Revenge
> `.mix` data files (the client asks for them on first run). The server itself
> needs no game data.

## Test

```sh
mix test                                  # unit tests (irc escaping, accounts, opts)
```

Protocol-level end-to-end smoke tests (run against a server started with
`mix run --no-halt` in another shell):

```sh
mix run --no-start priv/smoke.exs         # WOL: login → lobby → create/list/join → gameopt → startg
mix run --no-start priv/gserv_smoke.exs   # gserv: create/join → map transfer → load → start → action relay
mix run --no-start priv/qm_smoke.exs      # quick match: queue → pair → Matched → STARTG → gserv-join
```

(`qm_smoke.exs` needs the server started with a `QM_TEMPLATE` env so a template
exists without first playing a custom game.)

Both drive a minimal WebSocket client (`test/support/ws_client.ex`) through the
full flow and assert the exact replies the client expects.
