# Exact Message-ID protocol acceptance (WOOT-59 / PR #45)

This is an opt-in synthetic acceptance fixture, not a production IMAP client or the shared VPS runner. It exercises the real `Net::IMAP`, `Imap::Session`, move recovery and provider-managed Sent paths against Dovecot.

## Run on an authorized Linux test host

Requirements: Docker daemon access, rbenv with the repository Ruby version, installed bundle dependencies, and connectivity from the host to a private Docker bridge. Do not run on a developer Mac, against a production mailbox, or against shared database/Redis services.

Pull the three immutable images referenced by `run.sh` using `docker pull <image@sha256:digest>`, then run from the repository:

```sh
bash ops/imap-message-id/run.sh
```

The runner creates fresh resource-limited PostgreSQL, Redis and Dovecot containers on a unique **internal** network, with **no published ports**. IMAP cleartext authentication and the literal synthetic password are fixture-only. Mail storage is temporary. Only these newly created containers, volumes and network are removed by the exit trap. The Rails test environment receives private database/Redis addresses; `DATABASE_URL` is unset. No SMTP is sent, no browser is used, and no shared worker/service is stopped.

The runner records source/dependency hashes, versions, image identities, container inspection, effective Dovecot configuration, test output and exit status under `.artifacts/woot59-protocol.*`. It does not replace or depend on WOOT-32 / PR #28's snapshot transport and shared VPS execution route.

## Acceptance matrix

- Move recovery: longer-only rejection; exact-only success; exact plus longer selects the exact UID; unrelated-only search returns no candidates; duplicate exact IDs remain ambiguous. In rejection cases the original retained in Other is unchanged.
- Provider-managed Sent: longer-only stays `awaiting_provider_copy` and is selected again on the next cycle; exact-only and mixed candidates attach only the exact UID; unrelated-only and empty remain awaiting; duplicate exact IDs remain a conflict. Every case asserts that no APPEND occurs during synchronization.
- Missing COPYUID: an actual MOVE followed by real SEARCH/FETCH selects only the exact destination UID.
- Missing APPENDUID: an actual APPEND followed by real SEARCH/FETCH rejects longer-only, selects the exact mixed candidate, and refuses duplicate-exact ambiguity.

Dovecot supports UIDPLUS, so the four receipt-fallback cases suppress **only the returned COPYUID/APPENDUID metadata** with RSpec wrappers. They do not mock MOVE, APPEND, SEARCH or FETCH. The longer-only APPEND fallback intentionally appends an unrelated header while requesting confirmation of the target ID to prove that a remaining substring candidate is not accepted; this is a boundary control, not an assertion that normal rendering produces mismatched IDs. Ordinary recovery and Sent cases do not suppress server responses.

## Recorded acceptance: October 5, 2026

`acceptance.txt` contains the complete output of the successful final run:

- Application revision: `7a5771bbdc77912f167f59a91351a875fce3e903` (PR #45's existing repair); no application changes in this verification follow-up.
- Fixture files were then untracked; their exact SHA-256 hashes are recorded in the output. The empty tracked diff hash does not imply the new fixture was absent.
- Host: `mre-build`, Linux `6.8.0-138-generic`; Ruby 3.4.4; Rails 7.2.3.1; RSpec core 3.13.0; net-imap 0.6.4.1; Mail 2.9.1.
- Dovecot 2.4.4 (`8b687aa65c`), immutable digest `sha256:723e3392fe16c6fad8ddc605ea767cc01b4bad9cd9f13eb1dbac15e79c89b2d4`. PostgreSQL/pgvector and Redis image digests are also recorded.
- **357 examples, 0 failures**: 15 real-protocol examples plus 342 existing IMAP service examples. Exit status **0**.
- RuboCop on the new spec and all seven original repair files, shell syntax and whitespace checks pass.
- The run's private containers and network were removed. Existing Rails enum deprecation warnings are unrelated.

This addresses review request R1's protocol-evidence gap; it is not a claim of production incidence, a production-data repair, or verification of Gmail provider protocol behavior against Google's servers.
