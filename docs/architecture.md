# Macroflow Backend: v1 Design

Status: proposed, with Milestone 1 implemented on 2026-07-20.

## Product assumption and scope

No product brief was provided. This design therefore assumes Macroflow is a
personal nutrition application in which a person defines daily macronutrient
targets and records food consumption. This assumption affects the proposed
domain model and API only. The Milestone 1 scaffold is domain-neutral.

The v1 backend covers accounts, a user's current profile and targets, reusable
food definitions, diary entries, and daily summaries. Social features,
coaching, payments, barcode/catalog ingestion, recommendations, and admin tools
are out of scope.

## Architecture

Macroflow starts as a single deployable Phoenix application organized as a
modular monolith:

```text
HTTP client
    |
Phoenix Endpoint -> Router / versioned API pipeline
    |
Controllers -> JSON presentation modules
    |
Phoenix contexts (Accounts, Nutrition, Diary)
    |
Ecto schemas and queries -> Repo -> PostgreSQL
```

Requests terminate at thin controllers. Context modules own authorization-aware
use cases and transactions. Ecto schemas describe persistence and validate
changes; they do not become a general business-logic layer. JSON modules own
the external representation, keeping database structs out of the API contract.

The initial runtime is one OTP supervision tree containing telemetry, the Ecto
repository, cluster discovery, PubSub, and the Bandit-backed Phoenix endpoint.
Background workers will be introduced only when a concrete asynchronous use
case exists.

### Context boundaries

- `Accounts`: identity, credentials, sessions, profile, and account lifecycle.
- `Nutrition`: macro targets and reusable food definitions.
- `Diary`: consumption entries and daily aggregate queries. It may read through
  public functions from `Nutrition`; it must not reach into another context's
  private query modules.

Transactions that span contexts live in a dedicated use-case function in the
context that owns the user action, using `Ecto.Multi`. Cross-context database
associations are allowed, but cross-context calls remain explicit.

## Folder structure

The current Milestone 1 files and planned v1 additions are:

```text
.
|-- config/                         environment and runtime configuration
|-- docs/
|   `-- architecture.md             this design and decision record
|-- lib/
|   |-- macroflow.ex                domain namespace
|   |-- macroflow/
|   |   |-- application.ex          OTP supervision tree
|   |   |-- repo.ex                 database boundary
|   |   |-- mailer.ex               outbound email boundary
|   |   |-- accounts.ex             planned Accounts public API
|   |   |-- accounts/               planned account schemas/queries
|   |   |-- nutrition.ex            planned Nutrition public API
|   |   |-- nutrition/              planned target/food schemas/queries
|   |   |-- diary.ex                planned Diary public API
|   |   `-- diary/                  planned entry/query modules
|   |-- macroflow_web.ex            shared web definitions
|   `-- macroflow_web/
|       |-- endpoint.ex
|       |-- router.ex
|       |-- telemetry.ex
|       |-- controllers/            HTTP orchestration
|       |-- plugs/                  planned auth/request concerns
|       `-- api/                    planned versioned JSON/error modules
|-- priv/
|   |-- gettext/                    translatable messages
|   `-- repo/
|       |-- migrations/             append-only schema history
|       `-- seeds.exs
`-- test/
    |-- macroflow/                  context and domain tests
    |-- macroflow_web/              API contract tests
    `-- support/                    shared ExUnit cases/fixtures
```

Files are grouped by domain inside the application rather than split into an
umbrella. An umbrella adds release, dependency, and cross-application contract
overhead that the first version does not yet earn.

## Data model

All primary and foreign keys are UUIDs. All tables use UTC microsecond
timestamps, and mutable rows use optimistic locking where concurrent editing
would otherwise lose data.

### Relationships

```text
users 1---1 profiles
users 1---* user_tokens
users 1---* macro_targets
users 1---* foods (custom foods; owner is nullable for system foods)
users 1---* diary_entries *---0..1 foods
```

### Proposed tables

#### `users`

- `id`: UUID primary key
- `email`: case-insensitive email, unique
- `hashed_password`: credential hash; plaintext is never persisted
- `confirmed_at`: nullable UTC timestamp
- `status`: `active | disabled | deletion_pending`
- `inserted_at`, `updated_at`

#### `user_tokens`

- `id`: UUID primary key
- `user_id`: required, indexed, cascade delete
- `token_hash`: unique binary digest; raw bearer/reset tokens are not stored
- `context`: session, confirmation, password reset, or email change
- `expires_at`, `inserted_at`

#### `profiles`

- `user_id`: UUID primary key and foreign key
- `display_name`: optional string
- `timezone`: required IANA timezone name
- `unit_system`: `metric | imperial`
- `inserted_at`, `updated_at`, `lock_version`

#### `macro_targets`

- `id`: UUID primary key
- `user_id`: required, indexed
- `effective_from`: local calendar date
- `energy_kcal`: positive integer
- `protein_g`, `carbohydrate_g`, `fat_g`: non-negative decimals
- `inserted_at`, `updated_at`, `lock_version`
- unique key: `(user_id, effective_from)`

Targets are effective-dated instead of overwritten so historical diary views
continue to use the target that was active on that date.

#### `foods`

- `id`: UUID primary key
- `owner_user_id`: nullable; null means system-owned, indexed
- `name`: required string
- `brand`: optional string
- `serving_quantity`: positive decimal
- `serving_unit`: normalized string such as `g`, `ml`, or `item`
- `energy_kcal`: non-negative integer per serving
- `protein_g`, `carbohydrate_g`, `fat_g`: non-negative decimals per serving
- `archived_at`: nullable timestamp for soft removal
- `inserted_at`, `updated_at`, `lock_version`

User-owned foods are private. System-owned foods are readable by everyone but
writeable only through a future administrative boundary.

#### `diary_entries`

- `id`: UUID primary key
- `user_id`: required, indexed
- `food_id`: nullable reference using `ON DELETE SET NULL`
- `consumed_at`: required UTC timestamp
- `local_date`: required date derived using the profile timezone at creation
- `meal`: `breakfast | lunch | dinner | snack`
- `servings`: positive decimal
- immutable snapshot fields: food name, serving quantity/unit, energy and macros
- `notes`: optional bounded string
- `inserted_at`, `updated_at`, `lock_version`
- composite index: `(user_id, local_date, consumed_at)`

Nutrition is snapshotted into each diary entry. Editing or archiving a food
therefore cannot rewrite history. `local_date` is stored deliberately: timezone
changes must not silently move historical entries between diary days.

### Numeric and time rules

- Gram and serving amounts use fixed-precision decimals, never floating point.
- Calories use integer kilocalories in v1; API consumers do not send unit labels
  in numeric fields.
- Instants are ISO 8601 UTC timestamps. Diary-day parameters are ISO 8601 dates.
- A user's timezone is an IANA identifier and is applied at entry creation.

## API contract

The public contract is REST-style JSON under `/api/v1`. HTTPS is mandatory in
production. Clients send `Accept: application/json`; requests with bodies send
`Content-Type: application/json`. Authenticated endpoints use a bearer session
token. UUIDs are opaque strings.

This is a proposed contract, not implemented in Milestone 1.

### Conventions

Successful single-resource responses use `{"data": {...}}`; collections use
`{"data": [...], "meta": {...}}`. Errors use:

```json
{
  "errors": [
    {
      "code": "validation_failed",
      "detail": "Request validation failed",
      "source": {"pointer": "/data/email"}
    }
  ],
  "request_id": "..."
}
```

Collection pagination is cursor-based with `page[after]` and `page[limit]`
(default 20, maximum 100). Timestamps are ISO 8601 UTC. Unknown input fields
are rejected. Mutating endpoints that clients may retry accept an
`Idempotency-Key`; the server scopes keys to the authenticated user and route.

### Endpoints

| Method | Path | Auth | Purpose | Success |
|---|---|---:|---|---:|
| POST | `/api/v1/auth/registrations` | No | Create an account | 201 |
| POST | `/api/v1/auth/sessions` | No | Exchange credentials for a session | 201 |
| DELETE | `/api/v1/auth/sessions/current` | Yes | Revoke the current session | 204 |
| POST | `/api/v1/auth/password-resets` | No | Request a reset without revealing account existence | 202 |
| PUT | `/api/v1/auth/password-resets/{token}` | No | Set a new password | 204 |
| GET | `/api/v1/me` | Yes | Read the current profile | 200 |
| PATCH | `/api/v1/me` | Yes | Update profile preferences | 200 |
| GET | `/api/v1/macro-targets` | Yes | List effective-dated targets | 200 |
| POST | `/api/v1/macro-targets` | Yes | Create a target for a date | 201 |
| PATCH | `/api/v1/macro-targets/{id}` | Yes | Correct a target | 200 |
| GET | `/api/v1/foods` | Yes | Search system and owned foods | 200 |
| POST | `/api/v1/foods` | Yes | Create a custom food | 201 |
| GET | `/api/v1/foods/{id}` | Yes | Read an accessible food | 200 |
| PATCH | `/api/v1/foods/{id}` | Yes | Update an owned food | 200 |
| DELETE | `/api/v1/foods/{id}` | Yes | Archive an owned food | 204 |
| GET | `/api/v1/diary-entries?date=YYYY-MM-DD` | Yes | List one diary day | 200 |
| POST | `/api/v1/diary-entries` | Yes | Record consumed food | 201 |
| PATCH | `/api/v1/diary-entries/{id}` | Yes | Correct an owned entry | 200 |
| DELETE | `/api/v1/diary-entries/{id}` | Yes | Delete an owned entry | 204 |
| GET | `/api/v1/daily-summaries/{date}` | Yes | Return consumed totals and effective target | 200 |

Authorization failures use 401 when no valid session exists. Reads and writes
to another user's UUID return 404 to avoid disclosing existence. Validation
uses 422, conflicts use 409, unsupported media types use 415, and throttling
uses 429 with `Retry-After`.

## Milestones

### Milestone 1 — foundation (implemented; awaiting approval)

- Generate a Phoenix 1.8.9 API-only project.
- Keep Ecto/PostgreSQL, Bandit, telemetry, PubSub, Gettext, and Swoosh.
- Configure UUID generation defaults and UTC timestamps.
- Establish the application/test skeleton and repository documentation.
- Fetch locked dependencies, format, compile with warnings as errors, and run
  the generated test suite.

Exit criterion: a clean `mix precommit` on the supported local toolchain.

### Milestone 2 — identity and API foundation

- Confirm the product assumption and approve the API conventions.
- Implement account registration, confirmation, password reset, bearer
  sessions, profile/timezone handling, and ownership plugs.
- Add consistent error rendering, request validation, rate-limit boundaries,
  and API contract tests.

Exit criterion: authenticated `/api/v1/me` flow works end to end, with security
and negative-path tests.

### Milestone 3 — nutrition catalog and targets

- Implement effective-dated macro targets and private/system food visibility.
- Add cursor pagination, search, archive semantics, constraints, and indexes.

Exit criterion: users can safely manage targets and private foods without
cross-user access.

### Milestone 4 — diary and summaries

- Implement nutrition snapshots, diary CRUD, local-date behavior, and daily
  aggregate queries.
- Add concurrency, idempotency, query-plan, and timezone boundary tests.

Exit criterion: a diary remains historically stable when foods or timezones
change and summary queries meet an agreed latency budget.

### Milestone 5 — production readiness

- Add deployment/release configuration, secret management, database backups,
  structured observability, health/readiness probes, CORS policy, rate limits,
  API documentation generation, and operational runbooks.
- Run security, load, restore, and rolling-deployment checks.

Exit criterion: production readiness review and rollback exercise pass.

No Milestone 2 work starts without explicit approval.

## Risks and mitigations

| Risk | Impact | Mitigation / decision gate |
|---|---|---|
| The nutrition-product assumption is wrong | Data and API design would be irrelevant | Confirm scope before Milestone 2; Milestone 1 remains neutral |
| Food/catalog requirements expand quickly | Search quality, licensing, and data volume can dominate the system | Keep v1 to user/system foods; select a licensed external catalog separately |
| Timezone changes corrupt diary-day meaning | Entries appear on different days and summaries drift | Persist both UTC instant and creation-time local date |
| Mutable food data rewrites history | Past macro totals change unexpectedly | Store immutable nutrition snapshots on diary entries |
| Cross-user data leakage | Severe privacy incident | Scope every context query by current user and test foreign UUIDs as 404 |
| Token theft or database leakage | Account compromise | Store token digests, expire/revoke sessions, require TLS, redact logs |
| Decimal rounding differs across clients | Totals disagree | Fixed precision in PostgreSQL; server is authoritative for totals |
| Concurrent edits lose updates | Silent user data loss | Optimistic locks and conflict responses on mutable records |
| Unbounded list/aggregate queries | Latency and database pressure | Cursor limits, composite indexes, bounded date ranges, query-plan tests |
| Premature infrastructure | More failure modes and slower delivery | Add queues, caches, and service splits only against measured needs |

## Decisions

Each accepted choice should eventually move into an ADR if it becomes costly to
reverse. These are the initial decision records.

| ID | Decision | Why | Consequence / revisit trigger |
|---|---|---|---|
| D-001 | Modular monolith in one OTP app | Fast transactions and refactoring with clear context boundaries | Split only when independent scaling or ownership is demonstrated |
| D-002 | Phoenix 1.8.9 on Elixir `~> 1.17` | Current stable generator with a supported language floor | CI must test the chosen OTP/Elixir matrix before production |
| D-003 | JSON REST API at `/api/v1` | Native HTTP semantics, broad client/tool support, simple cache and auth model | Consider GraphQL only for proven client query-shape pressure |
| D-004 | PostgreSQL through Ecto | Strong constraints, transactions, mature indexing, and Phoenix support | Operate one primary datastore until a measured need appears |
| D-005 | UUID identifiers | Safe opaque public IDs and easier distributed data creation | Larger indexes than integers; use ordered pagination keys |
| D-006 | Bandit HTTP adapter | Phoenix default, lightweight, and maintained in Elixir | Revisit only for a missing protocol/operational capability |
| D-007 | Contexts own use cases | Prevent controllers and schemas from becoming coupled application logic | Context APIs require active review to avoid becoming grab bags |
| D-008 | Separate JSON presentation modules | Prevent accidental field exposure and persistence/API coupling | Adds small explicit mapping cost |
| D-009 | Effective-dated targets and entry snapshots | Preserve historical truth | More storage and explicit update semantics |
| D-010 | Bearer sessions with hashed server-side tokens | Revocation and device/session control without storing raw tokens | Requires a database lookup or safe cache per request |
| D-011 | Runtime production secrets/config | One artifact can be promoted across environments without embedded secrets | Startup fails fast when mandatory variables are absent |
| D-012 | Keep Gettext and Swoosh boundaries | Validation localization and transactional account email are likely | Remove before Milestone 2 if product scope excludes them |
| D-013 | No job queue/cache in Milestone 1 | There is no concrete workload that justifies either dependency | Add when delivery guarantees or measured database load requires it |
| D-014 | Tests at context and HTTP-contract boundaries | Protect business rules and the observable API while allowing internal refactors | Add narrow unit tests only for complex pure logic |
| D-015 | OpenAPI deferred until contract approval | Avoid presenting an assumed domain contract as executable truth | Produce and validate OpenAPI at the start of Milestone 2 |
