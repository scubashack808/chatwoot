# Maintained VPS backend test route

Detailed contract for `bin/vps-rspec`. Day-to-day usage lives in `AGENTS.md`;
this file is the reference for how the route behaves and how to maintain it.

## What it does

`bin/vps-rspec` submits your **actual working tree** — staged, unstaged and
selected untracked files — to the maintained VPS runner and returns the real
RSpec result. It exists because Factory sessions have no Ruby, no bundler and no
Docker, so backend specs cannot run locally.

```
bin/vps-rspec spec/models/account_spec.rb
bin/vps-rspec spec/models/account_spec.rb:42
bin/vps-rspec --include-untracked spec/support/my_helper.rb spec/models/account_spec.rb
bin/vps-rspec --preflight
bin/vps-rspec --dry-run spec/models/account_spec.rb
```

## Pieces

| Path | Role |
| --- | --- |
| `bin/vps-rspec` | Entry point. Node only, no Ruby or gems needed locally. |
| `ops/vps-tests/client/` | Snapshot, transport and CLI implementation. |
| `ops/vps-tests/runner.sh` | Remote runner. Sent with every snapshot and hashed. |
| `ops/vps-tests/runtime.json` | Transport, image, limits and selection rules. |

The runner travels with each run and its hash is recorded in the manifest, so a
stale copy on the host cannot silently apply different rules.

## Source identity

HEAD is not the source identity — your uncommitted bytes are. Each run:

1. Reads the current on-disk bytes into a private scratch copy.
2. Records sorted path, mode/type and SHA256 for every file, plus tracked
   deletions, into a manifest.
3. Transfers a checksummed archive over scp to a unique run directory.
4. The runner re-hashes every extracted file against the manifest **before**
   running anything and refuses on any mismatch.

Selection rules (`runtime.json`):

- **Tracked files** are always included, honouring deletions. Tracked files are
  source by definition — `config/rds-ca-2019-root.pem` and `.env.example` are
  tracked and belong in the snapshot.
- **Untracked files** are included automatically only under the documented
  source roots (`app`, `lib`, `config`, `db`, `spec`, `enterprise`, …).
- Anything else needs `--include-untracked PATH`.
- Untracked secret-bearing paths (`.env`, `*.key`, `config/credentials/`) are
  never swept in, and are **refused by name** if explicitly selected rather than
  silently dropped.

Your index, HEAD, branch and files are never modified: the client only issues
read-only git commands and verifies the tree state is byte-identical afterwards.
A dirty tree stays dirty in exactly the same way.

## Runtime and cache freshness

The runner refuses before running tests when identity does not match:

- Pinned image must exist with the required platform.
- Image Ruby must equal the snapshot's `.ruby-version`.
- Dependency key = image ID + hashes of `Gemfile`, `Gemfile.lock`,
  `.ruby-version`, `package.json`, `pnpm-lock.yaml`, `.npmrc`,
  `pnpm-workspace.yaml`. Caches are keyed on it, so a compatible cache is reused
  without reinstalling, and changed locks get a fresh cache.
- Asset key covers the **entire** submitted snapshot plus the dependency key.
  That rebuilds assets more often than strictly needed, which is the intended
  trade: a narrower key silently misses `vite.config`/`package.json` changes.

Caches live under `/opt/chatwoot-vps-tests/caches/`, owned by this route. The
retained hunt caches and the old gate are never written or reused in place.

## Isolation and concurrency

Each run takes a route-owned `flock`. A waiting caller either proceeds or exits
**75** (`EX_TEMPFAIL`) with a documented busy message, so two callers never share
mutable state. Postgres and Redis are freshly created per run, labelled
`chatwoot-vps-tests`, on an `--internal` network with a generated password and no
published ports. Limits from `runtime.json`: 4 CPUs, 6 GiB (swap capped equal),
512 PIDs. The test container receives only the snapshot, the generated service
settings and validated caches — never the Factory environment, SSH keys or a
Docker socket. Cleanup removes only that invocation's containers; receipts and
compatible caches are retained.

## Failure propagation

A passing-looking log never becomes a pass. The client's verdict is the remote
process exit status, with the receipt as evidence:

| Exit | Meaning |
| --- | --- |
| 0 | Specs passed |
| 1 | Specs failed |
| 2 | Snapshot refused or verification mismatch (bad selector, secret path, hash mismatch) |
| 3 | Transport unavailable or failed, or no receipt returned |
| 75 | Route busy |
| 91 / 92 | `bundle install` / `db:test:prepare` failed |
| 96 / 97 | No JSON results, or the selector matched zero examples |

96 and 97 exist because "no tests ran" is a failure, not a pass.

## Runtime refresh procedure

When the pinned image can no longer satisfy the submitted requirements, the
runner refuses and names the mismatch. To refresh:

1. Build or pull a compatible image **on the VPS** for `linux/amd64`.
2. Verify it: `docker run --rm <image> ruby -v` against `.ruby-version`.
3. Update `image.id` and `image.platform` in `ops/vps-tests/runtime.json`.
4. Rerun `bin/vps-rspec`; a new dependency key creates a fresh cache. Old
   compatible caches are preserved.

Never edit a lockfile to match an old image, and never reuse stale dependencies.

## Prerequisite status

The route needs the standard `ssh`/`scp` client in the Factory session image.
That is a platform change owned by Root with the Mastra Factory lane (tracked in
mastra-factory PR #10, which adds `openssh-client`). Until it lands,
`--preflight` reports the gap and `--dry-run` still works, but the route is not
ready for shared use.

Endpoint `100.66.60.55:41922` is reachable from Factory today and the persistent
machine key matches the target's authorized-key metadata. Host verification stays
on; the expected host fingerprint is pinned in `runtime.json`.

WOOT-18 cleanup note: this route depends on image
`sha256:6a6d171f…3874c25`. Treat it as referenced.
