# Rendered-entry readiness correction

## Observed defect

Exact candidate 9e12f7b42d411fa5f02ce5777fbad64aa779168f, run 20260928T182616735158Z: document loading returned native True after 11.782964 seconds. The signed-in profile appeared while conversation messages and email addressing controls were still loading. The subsequent draft guard refused before logout, credential input or Send. Cleanup, caller release and restoration passed. This failed attempt remains failed.

Independent read-only review identified an inherited ordering defect: profile text alone does not establish an inspectable conversation. The document-timeout correction did not introduce it. The screenshot and source support incomplete rendering; the failed guard did not retain its individual flags, so no specific draft operand is claimed as directly observed.

## Acceptance for the correction

Written before implementation and affected qualification:

1. After the authorized document reload, wait read-only for the actual admitted entry: visible login form, the exact synthetic dashboard, or the exact seeded conversation with its rendered message panel, editor and visible CC control. Profile presence and a partially mounted ReplyBox must not suffice. A missing unrelated list-spinner condition must not block readiness.
2. Reuse the existing 90-second rendered-state budget and 300-second enclosing browser deadline. No navigation, logout, input, Send retry, internal application-state mutation or installed-driver change is added while waiting.
3. Run the unchanged strict draft/attachment/addressing guard after readiness and retain its rejection rules. Waiting for inspectability never approves recipient values or clears a draft. Original preflight guards still run before lifecycle interruption and reload.
4. Retain Boolean draft-state flags before either pass or refusal, without recording input values, draft contents or credentials. Evidence errors still release the caller.
5. Tests exercise the actual main-flow wait expression against the pinned header template and shell-to-ready states. They discriminate the faulty call site, wrong routes, hidden/missing controls, unrelated spinners, readiness exhaustion and real drafts appearing after readiness. Existing helper tests remain intact.
6. Re-run the full native pilot on the final committed candidate, including negative controls and restoration. Retain exact-head commands/results and the independent re-review in PR #30. Never relabel the earlier successful working-tree runs or the new failed attempt.

## Boundaries

Only repository-owned verification code, tests and operating evidence change. The application remains the admitted d76b96565762a2b491fa444e9870ee216d9f63ca fixture. No product change, database reset, alternate browser/profile, real mail, timeout inflation, broader regression-map completion or deployment is included. Final qualification and publication status are recorded on the PR rather than rewriting this pre-implementation record.
