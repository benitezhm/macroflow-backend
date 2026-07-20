# Macroflow Backend

Phoenix JSON API for Macroflow.

Milestone 1 contains only the application skeleton. Domain schemas, migrations,
authentication, and public API routes are intentionally deferred until the
architecture is approved.

## Prerequisites

- Erlang/OTP 28
- Elixir 1.18 or later
- PostgreSQL

## Setup

```sh
mix setup
mix phx.server
```

The server listens on `http://localhost:4000`. There are no application routes
in Milestone 1.

## Quality checks

```sh
mix precommit
```

This compiles with warnings treated as errors, checks for unused dependencies,
formats the project, and runs the test suite.

## Design

The proposed v1 architecture, data model, API contract, milestones, risks, and
decision record are in [docs/architecture.md](docs/architecture.md).
