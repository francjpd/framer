# Connection trust model

The editor serves user content - uploaded stills and rendered exports - from a
Phoenix app that may bind every interface (`config/runtime.exs` uses
`{0, 0, 0, 0, 0, 0, 0, 0}` in production). The running app is the **main
computer** (the executioner): remote clients must be paired and explicitly
approved by the host operator before any content is served.

## Pairing

* On every application start `FramerWeb.Connections` mints **one**
  cryptographically secure random pairing id (`:crypto.strong_rand_bytes(32)`,
  URL-safe base64) and prints it to the host console and log. A fresh id is
  generated on each start; it is never persisted.
* A client presents that id with the framer CLI:

  ```bash
  FramerCore.CLI.main(["connect", "--id", "<pairing id>", "--server", "http://host:4000"])
  ```

  which calls `POST /api/connect`. Presenting the id does **not** grant access:
  it only creates a **pending** request and returns its id. The CLI then polls
  `GET /api/connect/:request_id`.

## Approval

* The host operator opens `/connections`, which lists the pending requests and
  lets them approve or deny each one.
* Approving a request issues that client an opaque session token that expires
  after one hour. Denying rejects it permanently.

## Session credentials

* An approved client receives the token from the poll response and sends it on
  every content request as `Authorization: Bearer <token>`.
* The token is verified server-side in memory and expires; an unknown, missing
  or expired token is rejected with `401`/`403` and no content.
* The host operator's own browser is issued a long-lived host session
  automatically, but only from a loopback connection, and carries it as a signed
  session cookie so the editor's `<img>` and download requests keep working.

## Protected surface

`GET /api/rigs`, `POST /api/rigs`, `GET|PUT /api/rigs/:id`,
`POST /api/rigs/:id/render`, `POST /api/rigs/:id/export`,
`GET /api/rigs/:id/source` and `GET /api/rigs/:id/result` all require an approved
connection. The pairing handshake (`POST /api/connect`,
`GET /api/connect/:request_id`) is intentionally unauthenticated - it is the
only path by which a client can become authorized.

No Ecto/Postgres is involved: the registry lives in memory for the lifetime of
the run, matching the filesystem-first persistence of the rigs themselves.
