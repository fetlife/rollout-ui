# rollout-cli integration work

## What this checkout provides

The rollout-ui repository owns the independent `rollout-cli/` gem and the opt-in
`lib/rollout/ui/api.rb` Rack application. The root server gem excludes the CLI;
the CLI gem has only JSON, HTTP, and option-parsing runtime dependencies.
[CLI usage](../rollout-cli/README.md) and the [normative API v1 contract](../rollout-cli/HTTP_API.md)
describe the supported surface. Existing browser routes are unchanged.

Local integration tests run the CLI executable over HTTP through Puma and a
prefixed Rack mount, using Rollout 3.1.0 and Active Record adapter 0.1.0 with SQLite.
A test-only bearer gate verifies transport and CLI error mapping; it is not FetLife
authentication. Independent CLI tests also cover controlled responses and TLS.
No fetlife-web source, deployment, production credentials, or production state was
changed or exercised.

## Verified source context (2026-09-30 local checkouts)

- Core `lib/rollout/logging.rb` exposes `events(feature, limit:)` and
  `global_events(limit:)`; events have feature, name, data, context, and created_at.
- `rollout-active_record-adapter/lib/rollout/adapters/active_record.rb` independently
  prunes feature/global visibility, selects newest records by timestamp/id, and
  returns those records in chronological order. API output reverses that order.
- Core `Rollout#delete` clears per-feature logging; it does not emit a deletion event.
- This repository's `lib/rollout/ui/web.rb` supports browser index/show JSON;
  `helpers.rb#feature_to_hash` excludes explicit users and history. These routes
  are not API v1 and should retain their existing behavior.
- Sibling fetlife-web `Gemfile.lock` pins rollout 3.1.0, rollout-ui 0.9.2, and
  rollout-active_record-adapter 0.1.0. `config/initializers/redis.rb` creates both
  `$rollout` and `$rollout_randomized` with the same Active Record adapter and
  `logging: { history_length: 100, global: true }`.
- FetLife `config/routes.rb` configures the UI with `$rollout` and the resolved
  employee nickname as actor, mounting it at `/admin/rollout`. Outside development,
  the browser mount uses `Constraints::Trusted`. This is not evidence of bearer
  token authorization or a usable CLI API.

Deployment/runtime and installed production gem versions were not checked.

## Implemented server behavior and local validation

The separate Rack API requires explicit `instance:` and `environment:` configuration.
It has no default mount or token store. Four GET-only routes provide full targeting
state and retained feature/global history, strict name/query/count/time validation,
and JSON errors with bounded output. Feature reads check existence before and after
loading state. Concurrent disappearance can return 404/503; the API is not a
transactional snapshot. The browser serializers and routes are unchanged.

History reads request at most N+1 events from the actual scope. They preserve
adapter tie ordering when reversed and filter inclusively. `oldest_available_at`
is deliberately null; completeness remains unknown. Known disabled logging returns
a disabled envelope; unsupported backends return 503.

Run tests with Ruby 3.4.2 (or another compatible Ruby), with Redis running for the
existing browser specs:

```sh
cd rollout-cli
bundle install
bundle exec rake test
cd ..
BUNDLE_GEMFILE=gemfiles/integration.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/integration.gemfile bundle exec rspec spec integration
```

The integration suite tests actual executable output, encoded names (space, percent,
slash, Unicode, dots), mounted paths, independent count retention, equal timestamps,
inclusive/date/duration filters, N+1 truncation, disabled/global-disabled logging,
zero retention, deletion/recreation, retained global updates, storage errors,
response bounds, and read-only database snapshots. CI runs the independent CLI
matrix and the integration/browser suite separately. SQLite validation does not
establish PostgreSQL/MySQL behavior or production proxy compatibility.

Local validation on 2026-09-30 passed on Ruby 3.4.2: 32 independent CLI tests
(555 assertions) and 44 browser/integration examples (29 browser, 15 API/CLI).
The integration bundle used published Rollout 3.1.0, Active Record adapter 0.1.0,
Active Record 8.1.4, SQLite3 gem 2.9.6, and Puma 8.0.2. Both gems built;
installed CLI help/version smoke checks passed. Gem manifests confirmed the API
is packaged, the server excludes the CLI, and CLI runtime dependencies remain
only `json`, `net-http`, and `optparse`. CI workflows were added but remote CI
was not run in this session.

Before host adoption, release a new rollout-ui version containing API v1 and build
and release the independent CLI gem. No core Rollout version bump is required.
This working tree prepares rollout-ui 0.10.0 (unreleased); published 0.9.2
must not be described as API-compatible. Upgrade the host pin to 0.10.0 only
after release and host acceptance tests.

## Companion fetlife-web change

1. Upgrade/pin rollout-ui to that release. Choose a separate API URL, for example
   `/internal/rollout/v1`, and set its environment from deployment configuration.
   Use `$rollout` to match the browser's stored state. The shared adapter means
   changes from the randomized instance share the same feature/global histories;
   this API does not evaluate randomized decisions.
2. Wrap only the new API mount in host-owned bearer authentication and authorization.
   Choose the host's token issuance/storage/rotation/revocation mechanism after
   reviewing existing authentication patterns. Give human/service principals a
   narrowly scoped rollout-read capability; explicitly authorize exposure of
   user IDs, feature data, and employee context. Do not reuse browser cookies or
   merely assume the existing browser route constraint authorizes bearer tokens.
3. Return JSON 401/403, never login redirects; keep mutation routes inaccessible
   through the API mount. Filter Authorization in Rails, proxy, and APM logs.
   Preserve browser authorization and actor attribution for existing writes.
4. Issue separate environment-specific credentials through the host's supported
   mechanism; distribute via a secret manager/private files and document revocation.
   Configure TLS and the reverse proxy to preserve encoded feature segments, enforce
   request/rate/response bounds, and avoid caching authenticated responses.
5. Add host request tests covering absent, invalid, expired/revoked, insufficiently
   privileged, and valid credentials, plus read-only method restrictions. Confirm
   no cookie is necessary and environment mismatches are caught by the client.

## End-to-end acceptance still required

Run the packaged executable against the actual authenticated application in a
controlled staging environment, with the real rollout-ui API and Active Record
adapter. Exercise list, show, feature history, global history, date/duration filters,
limit truncation, missing flags, and auth failures. Compare results with known
state and mutations made through the authorized application; confirm the CLI itself
creates no database changes or logging events. Verify shared-instance visibility,
retention/deletion behavior, proxy encoding, TLS, response limits, and secret
redaction. Record deployed gem versions and test evidence before claiming production
integration is complete. A production smoke check requires a deployed endpoint
and approved read credential; neither was established by this change.

Longer retention, deletion events, durable audit guarantees, richer pagination,
write commands, and MCP remain follow-up work.
