# Macroflow Personal Energy API: v1 Plan

Status: proposed for review. Milestone 1 was completed on 2026-07-20. No
Milestone 2 work may begin until this plan is explicitly approved.

## Product goal

Macroflow v1 is a private Phoenix API that receives Apple Health calorie totals
from an iPhone and calculates current and historical energy balance for a future
web dashboard.

The first useful outcome is answering, throughout the day:

> Given the calories recorded as eaten and burned so far, how many more calories
> can I eat while retaining my configured calorie deficit?

V1 supports:

- One manually provisioned user.
- Dietary energy consumed, written by Yazio into Apple Health.
- Active and basal energy burned, recorded through Apple Health.
- A user-configured daily calorie-deficit target.
- Current-day "burned so far" calculations.
- Single-day analysis and historical ranges of up to 90 days.
- An initial backfill of today and the previous 89 days.

V1 does not include a meal or food catalog, workouts, standing data, weight,
blood pressure, raw HealthKit samples, user registration, a dashboard UI, or a
Swift application. The iOS uploader is a separate future project; this backend
defines its integration contract.

## Architecture

Macroflow remains a single Phoenix application organized as a modular monolith:

~~~text
iPhone HealthKit uploader
          |
          | HTTPS JSON snapshots
          v
Phoenix Endpoint -> Router -> token authentication and authorization
          |
Controllers -> JSON presentation modules
          |
Accounts | Health | Energy contexts
          |
        Ecto Repo
          |
      PostgreSQL
~~~

Requests terminate at thin controllers. Context modules own authorization-aware
use cases and transactions. Ecto schemas describe persistence and enforce
changeset validation. JSON presentation modules keep persistence structs
separate from the external API.

The initial runtime remains one OTP supervision tree containing telemetry, the
Ecto repository, cluster discovery, PubSub, and the Bandit-backed endpoint. No
queue, cache, or additional service is introduced without a measured need.

### Context boundaries

- Accounts: personal profile, token provisioning, token verification, scopes,
  expiry, and revocation.
- Health: validation and idempotent replacement of HealthKit daily energy
  snapshots.
- Energy: effective-dated deficit goals and calculated daily summaries.

Contexts call one another through public functions rather than reaching into
another context's private schemas or query modules. Transactions spanning
multiple writes use Ecto.Multi in the context that owns the user action.

### Planned folder structure

~~~text
lib/
|-- macroflow/
|   |-- accounts.ex
|   |-- accounts/
|   |   |-- user.ex
|   |   `-- api_token.ex
|   |-- health.ex
|   |-- health/
|   |   `-- daily_energy_total.ex
|   |-- energy.ex
|   |-- energy/
|   |   `-- energy_goal.ex
|   |-- application.ex
|   `-- repo.ex
`-- macroflow_web/
    |-- controllers/
    |-- plugs/
    |-- endpoint.ex
    |-- router.ex
    `-- telemetry.ex

priv/repo/migrations/
test/macroflow/
test/macroflow_web/
docs/openapi.yaml
~~~

The project remains a single OTP application. An umbrella would introduce
deployment and cross-application boundaries that the personal v1 does not need.

## Time and calendar-day policy

Timestamps and calendar days solve different problems:

- Every stored instant uses UTC with microsecond precision.
- Health days use fixed Europe/Tallinn midnight-to-midnight boundaries.
- The iPhone explicitly queries HealthKit with the Tallinn timezone; changing
  the phone timezone while traveling does not redefine stored days.
- While traveling, an event near local midnight may belong to the neighboring
  Tallinn date. This is accepted in v1 to preserve stable, comparable days.
- Daylight-saving changes are handled by the IANA timezone database. A Tallinn
  day may therefore represent 23, 24, or 25 elapsed hours.

UTC is not used as the calendar-day boundary because UTC midnight differs from
the user's lived day. It would place some late meals and early workouts on dates
that do not match their natural daily interpretation.

The fixed-zone policy can later be replaced with travel-local days, but doing so
would require every uploaded interval to include its timezone and exact UTC
start and end, plus rules for travel days and historical recalculation.

## HealthKit aggregation and synchronization

### Daily totals instead of raw samples

The iPhone calculates merged daily totals using HealthKit statistics queries
with the cumulative-sum option. By default, HealthKit statistics merge data from
contributing sources. This avoids reimplementing Apple's source-merging behavior
and accidentally double-counting overlapping iPhone, Apple Watch, or app data.

The backend stores one daily snapshot containing:

- Dietary energy consumed.
- Active energy burned.
- Basal energy burned.
- The time at which HealthKit calculated the values.

For the current day, the snapshot covers Tallinn midnight through the
calculation time. It is a running total, not an end-of-day-only record. The
iPhone uploads the same date repeatedly, and the backend replaces the previous
snapshot rather than adding snapshots together.

~~~text
08:00  consumed 0      active 120  basal 550   -> store July 20
12:30  consumed 700    active 310  basal 900   -> replace July 20
18:00  consumed 1,400  active 850  basal 1,350 -> replace July 20
~~~

HealthKit additions, corrections, and deletions are handled on the phone by
recalculating and replacing each affected day. The API accepts any past date so
that corrections outside the initial backfill window remain possible.

This approach trades raw-sample auditability for smaller payloads, less
sensitive stored data, native HealthKit source merging, and a simpler backend.
The iPhone remains the source of truth and can resynchronize a day.

### Hybrid background synchronization

The iOS integration contract assumes this policy:

- Request immediate background delivery for dietary-energy changes. Meals are
  comparatively infrequent and directly affect the next eating decision.
- Request hourly background delivery for active and basal energy. These streams
  change frequently, so immediate delivery would create unnecessary wakeups.
- Coalesce notifications that arrive together into one synchronization.
- When notified, recalculate all three current-day totals and send one snapshot.
- Always recalculate and upload the current day when the app launches or returns
  to the foreground.
- Persist failed uploads locally and retry on the next background wake or
  foreground session.
- Allow only one synchronization to run at a time.
- Complete HealthKit observer callbacks promptly after the work has been safely
  processed or queued.

Background delivery is eventually consistent, not a real-time webhook. A
notification occurs only after data reaches the iPhone's HealthKit store, so
Apple Watch propagation can add delay. Foreground refresh is the dependable
path immediately before making a meal decision.

The API exposes both calculated_at and synced_at, allowing a dashboard to show
data freshness without claiming that the values are live. Background delivery
must be tested on a physical iPhone because Simulator behavior is insufficient.

## Data model

All primary and foreign keys use UUIDs. Mutable tables use UTC microsecond
timestamps. Database constraints duplicate critical changeset validation.

### Relationships

~~~text
users 1---* api_tokens
users 1---* daily_energy_totals
users 1---* energy_goals
~~~

### users

- id: UUID primary key.
- timezone: required IANA name, initially Europe/Tallinn.
- inserted_at and updated_at.

The personal user is created through a bootstrap Mix task. V1 has no email,
password, registration, password reset, or browser session.

### api_tokens

- id: UUID primary key.
- user_id: required foreign key with cascade deletion.
- name: required descriptive name.
- token_hash: unique SHA-256 digest; the raw token is never stored.
- scopes: constrained collection of permitted scopes.
- expires_at, last_used_at, and revoked_at: nullable UTC timestamps.
- inserted_at and updated_at.

The bootstrap task generates cryptographically random 256-bit tokens and prints
each raw token once:

- iPhone uploader: health:write.
- Future dashboard: energy:read and goals:write.

### daily_energy_totals

- id: UUID primary key.
- user_id: required foreign key with cascade deletion.
- date: required Tallinn calendar date.
- consumed_kcal: non-negative numeric(12,3).
- active_burned_kcal: non-negative numeric(12,3).
- basal_burned_kcal: non-negative numeric(12,3).
- calculated_at: required client-provided UTC timestamp.
- synced_at: required server-generated UTC timestamp.
- inserted_at and updated_at.
- Unique constraint on user_id and date.

A snapshot replaces the existing row only when calculated_at is newer. An exact
replay is idempotent. An older snapshot is ignored and reported rather than
overwriting fresher values.

### energy_goals

- id: UUID primary key.
- user_id: required foreign key with cascade deletion.
- effective_from: required Tallinn calendar date.
- daily_deficit_kcal: required non-negative integer.
- inserted_at and updated_at.
- Unique constraint on user_id and effective_from.

There is no medically selected default. A goal must be explicitly configured.
Effective dating prevents a later change from rewriting historical analysis.

## Energy calculations

For a synchronized day:

~~~text
total_burned       = basal_burned + active_burned
energy_balance     = consumed - total_burned
actual_deficit     = total_burned - consumed
calories_available = total_burned - target_deficit - consumed
~~~

Semantics:

- Negative energy_balance means a deficit; positive means a surplus.
- Positive calories_available means that amount could be consumed while
  retaining the configured deficit based on calories burned so far.
- Negative calories_available means the configured deficit has been exceeded by
  its absolute value.
- calories_available is never clamped to zero.
- If no goal applies, energy totals and balance remain available, while
  target_deficit_kcal and calories_available_kcal are null.
- Today uses burned calories recorded so far. V1 performs no full-day basal or
  activity projection.

Stored values retain three decimal places. API energy values are returned as
JSON numbers rounded consistently to one decimal place.

These calculations apply user-configured arithmetic; they do not prescribe a
deficit or provide medical advice.

## API contract

All application routes use JSON under /api/v1. Clients authenticate with a
bearer token. HTTPS is mandatory outside local development.

Single-resource responses use a data object. Collection responses use data and
meta objects. Errors use a stable code, human-readable detail, source pointer
when applicable, and Phoenix request ID.

### POST /api/v1/healthkit/daily-energy

Requires health:write. The request atomically accepts between 1 and 100
snapshots:

~~~json
{
  "data": [
    {
      "date": "2026-07-20",
      "timezone": "Europe/Tallinn",
      "calculated_at": "2026-07-20T15:00:00Z",
      "consumed_kcal": 1400.0,
      "active_burned_kcal": 850.2,
      "basal_burned_kcal": 1350.4
    }
  ]
}
~~~

Rules:

- All three totals are required, numeric, finite, and non-negative. Zero is a
  valid synchronized value.
- timezone must match the user's configured timezone.
- A date may not be in the future in that configured timezone.
- If any item is invalid, no item is persisted.
- A successful response reports inserted, updated, unchanged, and stale-ignored
  dates separately.
- Exact replays are safe without creating duplicate records.

### GET /api/v1/energy/days/{date}

Requires energy:read. Returns source totals, derived calculations, the effective
goal, calculated_at, and synced_at. An unsynchronized date returns 404.

### GET /api/v1/energy/days?from=YYYY-MM-DD&to=YYYY-MM-DD

Requires energy:read. The range is inclusive and limited to 90 days. The
response contains an entry for every requested date. Dates without a snapshot
use status "not_synced" and null energy fields.

### GET /api/v1/energy-goals

Requires energy:read. Returns effective-dated goals in descending effective-date
order.

### PUT /api/v1/energy-goals/{effective_date}

Requires goals:write. Creates or replaces the goal for the given date. The body
contains an integer daily_deficit_kcal.

### Operational endpoints

- GET /healthz: process liveness without a database dependency.
- GET /readyz: readiness backed by a lightweight database check.

An OpenAPI 3.1 document at docs/openapi.yaml will define exact payloads,
responses, security schemes, validation rules, and error shapes. It is the
integration contract for the future Swift uploader and dashboard.

### HTTP failure semantics

- 400: malformed JSON or query syntax.
- 401: missing, invalid, expired, or revoked token.
- 403: valid token without the required scope.
- 404: missing resource or unsynchronized single date.
- 413: batch exceeds the item-count or request-size limit.
- 422: semantically invalid input.
- 500: unexpected failure with no internal details exposed.

## Milestones

### Milestone 1: foundation — complete

- Phoenix 1.8.9 API-only project.
- Ecto/PostgreSQL, Bandit, telemetry, and PubSub.
- UUID generation and UTC microsecond timestamps.
- Application and test skeleton.
- Locked dependencies, formatting, compilation, and generated tests.

### Milestone 2: personal energy MVP — awaiting approval

- Remove unused mailer support and outdated food/diary assumptions.
- Implement personal bootstrap and hashed scoped-token authentication.
- Add user, token, daily snapshot, and effective-dated goal migrations.
- Implement ingestion, energy reads, goal management, liveness, and readiness.
- Add consistent JSON errors and the OpenAPI 3.1 contract.
- Run mix precommit and stop for review.

Exit criterion: mock HealthKit payloads can be synchronized idempotently and
queried as correct current-day and historical energy summaries through scoped
tokens, with the full quality gate passing.

### Milestone 3: iPhone integration validation

- Validate captured iPhone payloads against OpenAPI.
- Compare at least seven dates with Apple Health/Yazio within 0.1 kcal.
- Exercise the 90-day backfill, repeated snapshots, delayed corrections,
  foreground refresh, background delivery, and offline retry.
- Measure real-device synchronization delay and battery behavior.

The Swift uploader remains a separate project.

### Milestone 4: dashboard

- Display consumed, active, basal, total burned, actual deficit, available
  calories, configured goal, and synchronization freshness.
- Use the day and range endpoints without accessing raw health data.

### Milestone 5: future health extensions

- Add workouts as context without adding workout energy a second time.
- Add weight, standing time, blood pressure, and longer-term trends through
  separate typed measurements and endpoints.
- Revisit travel-local days only with explicit interval/timezone semantics.

No Milestone 2 work starts without explicit approval.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Yazio does not write complete dietary energy | Consumed totals are understated | Verify permissions and compare captured days with Yazio |
| Background delivery is delayed | Dashboard appears stale | Expose freshness and force foreground synchronization |
| Continuous immediate delivery drains battery | Excess wakeups and network use | Immediate dietary, hourly active/basal, coalesced uploads |
| Watch data reaches the phone late | Burned-so-far lags reality | Treat values as eventually consistent and show calculation time |
| Raw source overlap double-counts energy | Incorrect totals | Upload HealthKit's merged statistics |
| Replacement arrives out of order | Older data overwrites fresher totals | Compare calculated_at transactionally |
| Tallinn days feel wrong while traveling | Adjacent local-date placement | Document the home-zone rule and revisit explicitly |
| Token or database compromise | Health-data exposure | Hash and scope tokens, require TLS, redact logs, minimize data |
| Arithmetic is treated as medical guidance | Unsafe decisions | Never select a default deficit or call it medical advice |
| No raw samples limits investigation | Server cannot reconstruct a day | Keep the phone as source of truth and support resync |

## Architectural decisions

| ID | Decision | Rationale and consequence |
|---|---|---|
| D-001 | Modular monolith | Keeps deployment, transactions, and refactoring simple |
| D-002 | REST JSON under /api/v1 | Small explicit contract for the uploader and dashboard |
| D-003 | PostgreSQL through Ecto | Strong constraints, decimals, transactions, and indexing |
| D-004 | UUID identifiers | Opaque public identifiers without one central sequence |
| D-005 | One provisioned user with ownership keys | Personal v1 without blocking a future multi-user migration |
| D-006 | Separate scoped tokens | Uploader and dashboard get only the permissions they need |
| D-007 | Merged daily snapshots | Minimal sensitive data and HealthKit-native source merging |
| D-008 | Replacement ordered by calculated_at | Current-day uploads remain idempotent and monotonic |
| D-009 | UTC instants and Tallinn days | Unambiguous storage with stable human-day grouping |
| D-010 | Burned-so-far without projection | Report measurements without estimating the rest of today |
| D-011 | Hybrid background policy | Balances freshness, battery, and network activity |
| D-012 | Forced foreground synchronization | Dependable freshness before a meal decision |
| D-013 | Effective-dated deficit goals | Goal changes do not reinterpret earlier dates |
| D-014 | No default deficit | Avoids an implicit health recommendation |
| D-015 | Explicit JSON presentation modules | Prevents persistence changes from leaking into the API |
| D-016 | OpenAPI before the iOS client | Provides a reviewable, testable integration contract |
| D-017 | No queue or cache in v1 | The personal workload does not justify more infrastructure |

## Test and acceptance plan

- Bootstrap creates one user and independently scoped uploader/dashboard tokens.
- Raw tokens are shown once, stored only as hashes, never logged, and can be
  expired or revoked.
- Missing, invalid, expired, revoked, and incorrectly scoped tokens fail.
- Valid batches of up to 100 snapshots succeed atomically.
- A single invalid item rolls back the whole batch.
- Exact retries do not create duplicates.
- Older snapshots cannot overwrite newer values.
- Repeated current-day uploads replace rather than accumulate totals.
- Zero calories are valid and distinct from an unsynchronized date.
- Calculations cover deficits, surpluses, negative available calories, and
  missing goals.
- Goal changes affect only dates on or after their effective date.
- Range queries include every requested date and enforce the 90-day limit.
- Tallinn boundaries behave correctly across both daylight-saving changes.
- Changing the phone timezone does not change the fixed-Tallinn contract.
- API requests and responses conform to OpenAPI.
- Liveness does not depend on PostgreSQL; readiness does.
- mix precommit passes with clean formatting, warnings as errors, and no test
  failures.

## External assumptions requiring validation

- Yazio writes dietary-energy samples into Apple Health with sufficient
  completeness for the intended calculation.
- HealthKit merged statistics align with Apple Health and Yazio within the
  accepted 0.1 kcal comparison tolerance.
- The hybrid background policy provides acceptable latency and battery behavior
  on the physical iPhone and Apple Watch combination.
- Local development comes first. Before internet exposure, production requires
  TLS, runtime secrets, PostgreSQL backups, and operational monitoring.
