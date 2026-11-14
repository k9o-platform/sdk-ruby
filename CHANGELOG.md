# Changelog — k9o (Ruby)

## 1.5.2

### Changed

- `K9O_TIER_FEATURE_GATED` is no longer documented as an error to expect: the platform no longer gates features by plan.
- The `tierGating` option is removed from sign-in provider creation; the platform no longer gates features by plan.
- README: Architecture at a glance, illustrations, and the package table lists only the packages for that SDK.

## 1.5.0

### Added

- `approvals.comments.add(pending_id, body:, visibility:)` and `approvals.comments.list(pending_id, limit: nil, cursor: nil)`: comment on a pending change (`POST` and `GET /@<project>/pending-approvals/<id>/comments`). `body` is 1 to 4000 characters and `visibility` is `"everyone"` or `"approvers_only"`, fixed once posted; `pending_id`, `body`, `visibility` and `limit` (1 to 200) are checked before anything is sent (`K9O_INVALID_FIELD_VALUE`). `list` answers the comments the caller may see, oldest first, as a page with `next_cursor` (`nil` on the last page). Posting needs a session; a personal access token alone is refused (`K9O_RBAC_DENY`). `K9O_APPROVAL_COMMENT_NOT_ELIGIBLE` and `K9O_APPROVAL_COMMENT_CLOSED` arrive as `K9o::KError`.
- `realtime.replay(topic, from_sequence: nil, until_sequence: nil, limit: nil)`: read a batch of past events for a realtime topic (`POST /@<project>/realtime/replay`), the catch-up for `realtime.subscribe`. `topic` is required; `from_sequence` and `until_sequence` are whole numbers (0 or more) and `limit` is 1 to 10000 (`K9O_INVALID_FIELD_VALUE` before anything is sent). `data` is `{ "events", "nextCursor", "hasMore" }`, plus `"resync"` (`"reread-source"`) when the topic keeps no history, so re-read the current state. Events keep the gateway's spelling that `subscribe` yields. `audit.replay` is unchanged.
- `gate.sign_in` asks the project which region holds the email first (`POST /@<project>/gate/locate`, the email only, no credential) and sends the password to that region's host. The located host is used only if it is `https`, has no userinfo, port, path, query or fragment, and is your own org, gateway family and apex with the region code added or swapped in; otherwise the base URL is used. The answer is never cached; `refresh_token` and `sign_out` go to the host that issued the session, from a bounded in-memory hint. If the locate step answers 404, the base URL is used. A 429 `K9O_RATE_LIMITED` or 503 `K9O_GATE_REGION_UNAVAILABLE` from that step raises as `K9o::KError`, nothing else is sent, and the call is safe to retry.
- `crypto.mode` and `crypto.mode(crypt:)` return the gateway's `route` (`"client"` or `"server"`) as `Mode#route`, `nil` on older gateways or for an unknown value; follow it, not `custody_mode`.
- The custody check before each `crypto.encrypt` names the crypt (`GET /crypto/mode?crypt=<crypt>`), so a personal access token or workload policy scoped to named crypts can encrypt. `crypto.mode` sends no query.
- `crypto.mode(crypt: nil)`: an optional crypt for the public mode read (`GET /crypto/mode?crypt=<crypt>`); the crypt is checked before sending (`K9O_INVALID_FIELD_VALUE`), and `crypto.mode` is unchanged.
- `crypto.encrypt` follows the `route` in the project's mode answer. On a BYOK or HYOK project only an explicit route `"server"` sends plaintext to the platform (the answer then needs an epoch, otherwise `K9O_CRYPTO_CUSTODY_UNKNOWN`); a missing route uses your client core. A route that is not `"server"` or `"client"` raises `K9O_CRYPTO_CUSTODY_UNKNOWN` and nothing is sent. The mode is read on every call. `decrypt` and `rewrap` are unchanged.
- `crypto.crypts_list`, `crypto.crypts_create(name)` and `crypto.crypts_retire(name)`: list, register and retire crypt names. `create` sends only `{ name }`; a name outside 1 to 64 characters of a-z, 0-9 and `-` (or `actions`) raises `K9O_INVALID_FIELD_VALUE` (`field: name`) before anything is sent. Each answers a crypt as `{ "name", "status" ("active" or "retired"), "createdAt", "retiredAt" }`; a malformed gateway answer raises `K9O_INTERNAL_ERROR`. `K9O_CRYPT_ALREADY_EXISTS`, `K9O_CRYPT_LIMIT_EXCEEDED`, `K9O_CRYPT_RETIRED`, `K9O_CRYPT_NOT_FOUND` and access refusals arrive as `K9o::KError`. A retired or unregistered name only makes `encrypt` refuse it; `decrypt` and `rewrap` never read the registry. Needs `crypto:manage_crypts` (project admins by default); a personal access token is refused on retire.
- `K9o::KiboClientCore`: the client core for `k9o.crypto` on a BYOK or HYOK project. It opens and seals data on this machine against your own KMS or HSM, so the platform never sees plaintext or the key. Register it with `crypto.use_client_core`. The key, provider, region, role and endpoint all come from the configuration you pass; `expected_key_refs:` is required and non-empty, and the configured key must be in it. Before any token is fetched it checks that the bound core lists `expected_key_refs` (otherwise `K9O_CRYPTO_KEY_PIN_UNENFORCED`) and exports the 2.15.0 functions (otherwise `KIBO_WASM_ERROR`). A federated-token response that names another provider or project is refused with `K9O_INVALID_FIELD_VALUE` and nothing is exchanged. The exchange has a deadline (30 s, `exchange_deadline:`; `KIBO_EXCHANGE_TIMEOUT`); the exchanged credential is reused until 60 s before it expires, and a federated token is fetched on every call. A failed item is `{ "ok" => false, "code", "message" }` with the core's code (`UPSTREAM_KMS_ERROR` is your own KMS); a pin, capability, token or exchange problem raises `K9o::KError`. No token or credential appears in an error, `inspect` or `to_s`. A call whose own `expected_key_refs` does not contain the configured key is refused per item with `K9O_CRYPTO_UNEXPECTED_KEY` before the federated token is fetched and before the exchange.
- `K9o::KiboFfiCore`: a built-in bound core for `K9o::KiboClientCore` that works with the generated Ruby binding (`KiboKmsRestFfi`, zk-bundle-v2.16.3 or later). Pass `core: K9o::KiboFfiCore.new`. It converts the SDK's plain data to the binding's typed records, integer enums and federation variant, and the binding's errors to `CODE: detail` (`UPSTREAM_KMS_ERROR` for your own KMS failing); the cryptography stays in the native core. Requiring `k9o` does not load the binding; building the adapter without it raises `K9o::KError` (`KIBO_WASM_ERROR`). `library:` takes the absolute path of the native library, `binding_path:` the path of the binding file. The Vault federation field for the JWT login is `jwt_auth_mount` (the name Vault serves the JWT login under, `jwt` for `auth/jwt`; not the transit mount); the core receives it as its own `mount` field, and `vault_addr`, `jwt_auth_mount` and `role` are required for `provider: "vault"`.
- `K9o::Crypto::FederatedToken#provider` and `#project_id`: set when the gateway names them in the federated-token response, otherwise `nil`. They are only checked against your configuration.
- `crypto.federated_token(crypt, op)`: ask for a short-lived RS256 token (valid for at most 15 minutes) for one crypt and one operation (`"encrypt"`, `"decrypt"` or `"rewrap"`), answered as `K9o::Crypto::FederatedToken` (`token`, `expires_at`, `issuer`, `subject`, `audience`, `kid`). `crypt` and `op` are checked before sending (`K9O_INVALID_FIELD_VALUE`); the call is never retried; a response without any of the six fields raises `K9O_INTERNAL_ERROR`. The token is left out of `inspect`, `to_s` and `pp`.
- `expected_key_refs:` client option: an `Array` of the key identifiers (from your own cloud configuration) your BYOK or HYOK key may be. It is checked when the client is built (non-empty, no blanks, spaces or `*`; `K9O_INVALID_FIELD_VALUE` otherwise) and passed to the client core as the keyword `expected_key_refs:` on every `crypto.encrypt`, `decrypt` and `rewrap` call when set, so the core refuses any other key (version ignored) before it uses a token or makes a network call. A core declares that it does with a method `enforces_expected_key_refs?` that returns `true`; with the option set and no declaration the call raises `K9O_CRYPTO_KEY_PIN_UNENFORCED` before the core is called. `K9o::Crypto.key_ref_matches?(key_ref, expected, provider:)` is the comparison for core authors (`provider:` is required, one of `:aws`, `:gcp`, `:azure` or `:vault`, and is never guessed from the reference): AWS compares the whole reference; GCP without the version; Azure the first five parts in lower case; Vault `<path>/<key>` without `:<version>`.
- `custody.status`: read how the project's keys are held (`mode`, `attached`, `provider`, `lastJob`, and `hsm` for a hardware security module); read-only.
- `KError#retry_after_sec`: the wait the gateway asks for (seconds), or `nil`.
- `KError#request_id` is filled from the gateway's `x-k9o-request-id` response header (any letter case) when the error body carries no request id, on every error built from a non-2xx response, including a stream open; a request id in the body still wins, and it stays `nil` when neither is present.
- `require_approval` on single-record writes: `insert(record, require_approval: true)`, and `.require_approval` on `update` and `delete` builders. The write is sent with `?requireApproval=true` and may answer a queued change (HTTP 202); `K9o.queued_write?(result)` tells it from an applied row. `Meta#approval` carries `meta.approval`.
- `functions.triggers`: `list`, `create`, `update` and `delete` for event triggers.
- `schedules` namespace: `list`, `get`, `create`, `update`, `delete`, `runs` and `run_now`.
- `vectors` namespace: `nearest` and `upsert` for vector collections (names start with `_`), sending the embedding in the request body.
- `metadata` namespace: `filter`, `set`, `search`, `vectors.nearest`, `subscribe`, and `index.get` / `index.declare` for the columns you declare on a collection. Column names in `where`, `search` and `nearest` get the `metadata.` prefix when you leave it out; `set` writes declared columns only. `subscribe` uses the same reconnecting reader as `realtime.subscribe` (events carry the record id only) and takes `from_sequence:`. The SDK checks the surface grammar, limits, cursor rule and the 64-column limit before sending. Gateway codes such as `K9O_METADATA_FIELD_NOT_INDEXED`, `K9O_UNKNOWN_SURFACE` and `K9O_QUERY_RESULT_TOO_LARGE` arrive as `K9o::KError`.
- `rampart` namespace: `classify(input, label:)` answers the verdict and its signed receipt (advisory; a classifier outage raises `K9O_RAMPART_CLASSIFIER_UNAVAILABLE`), `jwks` reads the public key feed, and `verify_receipt(result_or_receipt, input)` checks a receipt locally (EdDSA, `typ`, issuer, project, clock skew, and the SHA-256 of the canonical `input`) and returns the verified verdict or raises `K9o::Rampart::ReceiptRefusal` with a closed `reason`. The issuer comes from the key feed (`issuer:` overrides it); the project is the `projectId` of the `classify` result (or `project_id:`), and a bare receipt string with neither is refused as `project_unknown`. Keys are cached for the client's life and refetched once on an unknown key id. `K9o::Jcs` (the platform's canonical form: keys sorted by UTF-8 byte order, integers only up to 2^53 - 1, so an input with a fractional number cannot be classified or verified) and `K9o::Ed25519` (openssl, with a built-in fallback) are included, with no new dependency. A long input is scored in overlapping windows and the highest injection score decides; past 16 windows (about 6,000 tokens) the answer is `413 K9O_RAMPART_INPUT_TOO_LONG` with no verdict, and `503 K9O_RAMPART_CLASSIFIER_UNAVAILABLE` still means the classifier could not answer. The thresholds (calibration `rampart-launch-v1`) are a starting calibration and may move; a change is a new `calibrationVersion`.
- `analytics` namespace for datasets: `list`, `query`, `create`, `get`, `delete`, `materialize`, `read` (cursor paging), `write`, `upload` (raw or multipart with a manifest), `download_original` (answers a `K9o::Download`), plus `analytics.rollups` and `analytics.schedules` (`create`, `list`, `delete`, `reattest`) and the project-wide `rollups` namespace (`list`, `read`, `subscribe`). `reattest` is for people only: a service, workload or extension token gets `403 K9O_RBAC_DENY` (`reason: human_only`), and a rollup or schedule that is not re-attested pauses when its interval ends.
- `keys` namespace: `list`, `get` and `rotate` for the project's encryption keys (metadata only; `list` takes `status:` `active` or `all` and is not paged). `rotate(key_id, step_up: hook)`: on `401 K9O_STEP_UP_REQUIRED` the SDK calls your hook with the challenge (`KError#step_up`), the HTTP method and the URL, sends the same request once more with the `x-k9o-step-up-proof` header built from its `{ method:, proof: }` answer, and never loops; without a hook the error carries the challenge. Rotation is never retried otherwise, and answers `409 K9O_STATE_CONFLICT` or `429 K9O_RATE_LIMITED` (at most 3 per rolling 24 hours) as `K9o::KError`.
- `audit.tail(types:, on_resync:)`: live audit events (`auditEventId`, `type`, `actorType`, `occurredAt`, `outcome`, and the frame's `eventId`) read from the gateway's frames (the audit event sits in `payload`; the frame's SSE `id` is the publisher's own id and the `Last-Event-ID` for a resume), on the reconnecting reader of `realtime.subscribe`; on a `replay-ledger` resync it reads the missed events through the new `audit.replay` after the last `auditEventId` delivered, page by page, and yields them once. `audit.replay` answers the typed page `{ events, nextCursor, hasMore }` (events flattened, `sequence` a string).
- `audit.tail` after a `resync` is gapless: it reconnects fresh and buffers that connection, replays from the last delivered `auditEventId`, then merges replay, buffered and live frames, each event once (a repeated resync backs off). `audit.replay` sends `limit: 1000` when you give none and refuses a limit above 10000 or below 1 with `K9O_INVALID_FIELD_VALUE`. A new connection starts at the live head and may re-send the last few seconds of events (each yielded once), and the informational `resync` that opens it is ignored.
- `rollups.subscribe` yields the cell from each `cell` frame's `payload` (with `eventId` and a `suppressed` flag for cells below the cohort threshold), resumes with the frame's `id`, and calls `on_resync` on `reread-source`.
- `crypto` namespace for server-side encryption with the project's key: `encrypt`, `decrypt` and `rewrap` (`POST /crypto/encrypt|decrypt|rewrap`), batches of up to 100 items, bytes in and out with the base64 done for you, `K9o::Crypto.text`, and client-side checks (`K9O_INVALID_FIELD_VALUE`, `K9O_PAYLOAD_TOO_LARGE`) before anything is sent. Never retried automatically. `encrypt` checks the custody mode (`crypto.mode`) on every call and never sends plaintext when the key is in your own KMS or HSM; `decrypt` and `rewrap` try the platform first and reroute client-side on `409 K9O_ZK_STORE_FLOW_REQUIRED`. Register the Kibo client core with `crypto.use_client_core`; without one those calls raise `K9O_ZK_CLIENT_CORE_UNAVAILABLE` (501). An unknown mode or a failed check raises and sends nothing. The gateway route is not live yet.
- `Rampart::Verdict#windows`: the number of windows the classifier scored, read from the signed `windows` claim (`nil` when absent); unknown claims are ignored. `413 K9O_RAMPART_INPUT_TOO_LONG` raises as `K9o::KError`.
- `KError#retry_after_sec` also reads the `Retry-After` response header (whole seconds) when the body gives none.
- `K9o::Moat`: a local guard for one model call with no network access. It pins the system prompt, refuses role and system markers in untrusted input, checks input and output against a documented JSON Schema subset, and runs an optional PII filter you pass in. Refusals raise `K9o::Moat::Refusal` with `reason` `role_marker`, `input_schema`, `output_schema` or `pii`.
- `K9o::Moat` role-marker scan follows the shared normalisation rule: NFKC, combining marks ignored, default-ignorable and format code points removed, a small set of Cyrillic and Greek look-alikes of the marker letters read as the Latin letter (not general homoglyph detection), case-folded, horizontal whitespace collapsed, then matched line by line; it passes the shared marker vectors.
- `end_users` namespace: `list`, `get` and `role_grants` (`list`, `grant`, `revoke`).
- `approvals.list` pages: optional `cursor:` (from `meta.cursor.next`, `nil` on the last page) beside `status:` and `limit:`.
- `approvals.bulk` result carries `failed`, a list of `{ "id", "code", "reason" }` for rows that did not apply (empty when none); the call answers HTTP 200 even when rows fail.

- `realtime.subscribe` resumes: it reconnects with `Last-Event-ID` when the stream ends or the network fails (backoff up to 30 seconds), drops duplicate events by `eventId`, ignores heartbeats, abandons a connection idle for 45 seconds, and calls the new optional `on_resync:` handler (without yielding the frame) before continuing from a fresh connection. Events carry `eventId`.
- README: what an event-trigger function receives (the JSON payload, redaction, `triggeredAt`, and deduping on `eventId`).

### Changed

- The read timeout is 120 seconds (was 30), as in the Python SDK, so a long call such as Rampart `classify` on a long input is not cut off. A client you pass in with `http_client:` keeps being set to the same value.

- `vector_search` on the select builder sends the embedding in the request body (`POST data/<collection>/search`), so real embeddings work. It cannot be combined with `text_search`.
- The approval policies README no longer says the builders do not send `requireApproval`.

### Fixed

- `realtime.subscribe`, `metadata.subscribe` and `rollups.subscribe` no longer reconnect forever on a fresh connection. The gateway opens such a connection with an informational `event: resync` frame and then streams events on the same connection; the reader treated that frame as a lost position, so no event was delivered. A `resync` that is the first data of a connection sent with no `Last-Event-ID` and no `fromSequence` is now ignored (`on_resync` is not called and the connection is kept). A `resync` after an event, or on a connection sent with `Last-Event-ID` or `fromSequence`, is still a lost position: `on_resync` is called and the reader reconnects fresh. `audit.tail` is unchanged.
- `require "k9o"` no longer fails on Ruby 3.4 and later with `cannot load such file -- base64`: the vault code encodes and decodes base64 without the `base64` gem, which is no longer a default gem there and was not declared as a dependency.
- `audit.tail` and `audit.replay` read the gateway's real frames: the tail used to deliver no events, and a replay returned an empty list, because the decoders looked for the five audit fields at the top of the frame and took the SSE `id` for the audit event id. `rollups.subscribe` yielded the frame, not the cell.
- `Rampart#classify` raises `K9O_INVALID_FIELD_VALUE` for an `input` that is not a Hash, with a test; the gateway is going to refuse it with a 400.
- `keys.list` no longer exposes `nextCursor` (the list is not paged).

- `KError#recommendation` is always a string or `nil`. An object recommendation from the gateway (`{"action": ...}` or `{"retryAfterSec": ..., "note": ...}`) used to arrive as a Hash; it now gives its `action`, else its `note`.

## 1.4.0 — 2026-10-26

### Added

- `query(sql, params)`: one read-only SQL statement; an array binds `$1, $2, ...`, a hash binds `:name` placeholders.
- `search(collection, column:, q:)`: full-text search over one column, plus `text_search` and `vector_search` on `select`.
- `ai.generate`: text generation from a prompt (verb sugar over `compute.llms.invoke`; `model` defaults to the org's default LLM).
- `streams` namespace for user data streams: `create`, `list`, `get`, `delete`, `publish`, `replay` and `subscribe`.
  `subscribe` tails live events over SSE and reconnects from the last sequence when the server closes the connection.

- `approvals` namespace for the pending-change queue: `list`, `get`, `approve`, `reject` and `bulk`.
- `approval_policies` namespace: `list`, `create` and `delete`.
- `schema.collections.list`: the project's collections with row counts and last migration, paged by cursor.

### Changed

- The README description now covers streams and realtime, and the platform overview moved to an "About Kilimanjaro" appendix.
- Function deploy examples use the sandbox tier.

## 1.3.0 — 2026-10-26

Every method now matches the gateway.

### Changed

- `projects.create` takes `display_name:` (and optional `slug:`, `region:`, `custody_mode:`, ...);
  `projects.get` and `projects.update` use the projects routes.
- `functions.deploy` takes `name:`, `runtime:`, `tier:` (`gateway` or `sandbox`), `artifact_key:`, `version:` and `description:`.
  Inline code is gone.
- `functions.invoke` sends the payload as `{payload}`.
- `policies.create`, `update` and `validate` take a `policy:` document (plus optional `rules:`, `editor_mode:`);
  `policies.list` takes only `status:`.
- `audit.query` filters are `event_type:`, `actor_id:`, `after:`, `before:`, `limit:` and `cursor:`.
- Org roles, identity providers and default model use the current routes; `smtp.set` uses `password_ref:` and `from_address:`;
  `smtp.test` takes `to:` and `subject:`.
- `me.api_tokens.create` takes `label:` and `scope_manifest:` (and `ttl_seconds:`); `me.sessions.revoke` and `revoke_all` use new routes.
- `compute.llms.invoke` settings are sent flat, and the result has `content` and `usage`.
- `studio.workflows.trigger` sends the context as `triggerContext`.
- `gate.sign_out` requires the refresh token.
- The API host comes from the base URL: any `<org>.api.<apex>` host works and no apex is hardcoded.
  `https://api.k9o.io` is only the default.

### Removed

- `gate.verify_session`, `gate.hosted`, `realtime.replay` and `realtime.subscribe_poll`.
- `me.notifications`, `me.audit_log` and `me.data_export`.
- `org.groups.create`, `org.groups.delete`, `org.members.get` and `org.smtp.get`.

### Added

- `functions.upload_artifact(bytes, kind)` uploads a build and returns the `artifactKey` for `deploy`.
- `UrlGrammar.parse_api_host` reads the org, region and apex from any gateway host.
- A contract test checks every method against the gateway's API description.

## 1.2.0 — 2026-10-25

- The README now introduces the Kilimanjaro building blocks (Keep, Pulse, Gate, Kibo). No change to the public API.

## 1.1.1 — 2026-10-25

- Documentation links corrected: the documentation hub is https://docs.kilimanjaro.dev, with the website, platform API and console listed in a Links section. Package metadata points at the same places.

## 1.1.0 — 2026-10-25

- Documentation rewritten with runnable examples and expected output; internal cross-references removed from the published sources. No change to the public API.
- Error text for `update()` / `delete()` without an `id` filter no longer mentions a version or a roadmap.

## 1.0.0 — 2026-10-23

First public release. See the README for the full API overview.
