# WOOT-78 verification receipt

Executed October 3, 2026 on the remote Factory Linux sandbox, not a workstation.
Baseline: `cf01462236722ef24264029dfa358623dc11902f`.
Ruby 3.4.4; pg_isready 16.15 (Ubuntu).
Production delta: only `uri.port` -> `uri.port || 5432` in
`docker/entrypoints/helpers/pg_database_url.rb`.

From the repository root after `eval "$(rbenv init -)"`:

```sh
ruby .artifacts/verification/woot-78/verify.rb
ruby .artifacts/verification/woot-78/client.rb
ruby -c docker/entrypoints/helpers/pg_database_url.rb
sh -n docker/entrypoints/rails.sh
bundle exec rubocop docker/entrypoints/helpers/pg_database_url.rb
git diff --check
```

- `before.log`: 10/16 pass; all six omitted-port URL cases fail with missing `-p` value (expected exit 1).
- `after.log`: 16/16 pass (exit 0). Covers both URL schemes, URL precedence, explicit default/custom ports, and absent/empty URL or separate port. Synthetic password absent from helper output and shell trace.
- `client.log`: real client parses both omitted-port schemes at 5432 and exits 2 (no response), not 3 (bad arguments). This is NOT proof of a healthy database.
- Ruby/shell syntax and whitespace checks pass. RuboCop: one file inspected, no offenses. Existing bundle available; no dependencies installed.

The matrix executes the actual helper and extracts the two command-construction
lines from the unchanged Rails entrypoint. Its temporary pg_isready stub only
captures argv. Child environments exclude inherited database credentials.

Full startup integration remains pending separate authorization: an isolated
synthetic database must accept omitted/default/custom-port connections (exit 0),
then the unchanged Rails entrypoint must reach its final command under an external
timeout. No startup retry loop, Rails boot, migration, production action, worker
interruption, or historical hunt environment reuse occurred here.

Built on main's merged WOOT-1/29/30/31/38 work. No dependency on the open
WOOT-32/PR28 backend-spec route; no overlapping readiness repair identified.
