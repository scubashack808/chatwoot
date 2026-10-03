# WOOT-77 verification

Date: 2026-10-03
Base: cf01462236722ef24264029dfa358623dc11902f
Branch: fix/woot-77-empty-account-features

## Environment

Executed on the remote Linux Factory sandbox, not a developer Mac or production application. Rails test database: chatwoot_test_4941973b_f7b3_4e24_844d_c9f154b5ee5e, created and schema-loaded for this sandbox. A dedicated Redis process used the checkout-local .redis-77.sock socket (port disabled, persistence disabled). Installed locked pnpm dependencies to resolve missing Vite executable; no dependency manifest changes. No Playwright or existing worker/service interruption.

## Proof

Before production changes, ran the new enterprise request spec: 2 examples, 1 expected failure. The rendered all-unchecked form saved the account name but retained help_center. The legacy nonempty campaigns replacement control passed. See before.log.

After changes, ran:

```sh
bundle exec rspec spec/enterprise/controllers/super_admin/accounts_controller_spec.rb spec/controllers/super_admin/accounts_controller_spec.rb spec/models/concerns/featurable_spec.rb spec/models/account_spec.rb --format documentation
bundle exec rubocop enterprise/app/controllers/enterprise/super_admin/accounts_controller.rb spec/enterprise/controllers/super_admin/accounts_controller_spec.rb
git diff --check
```

All commands exited 0: 91 examples, 0 failures; two Ruby files, no lint offenses. Enterprise regression examples executed (not skipped). Coverage includes actual rendered hidden marker submission, empty-selection clearing and name persistence, marked and legacy nonempty replacement, omitted-marker preservation, and creation defaults. See after.log and lint.log.

## Patch registration handoff (not a registry entry)

WOOT-77 changes enterprise/app/views/fields/account_features_field/_form.html.erb and enterprise/app/controllers/enterprise/super_admin/accounts_controller.rb; coverage is spec/enterprise/controllers/super_admin/accounts_controller_spec.rb. Explicit form marker distinguishes all-unchecked updates from unrelated requests. No OSS/model/schema changes.

Upstream disposition: longstanding upstream behavior; no upstream fix or upstream submission verified. Removal condition: upstream implements equivalent explicit-empty versus omitted semantics and the retained regression/compatibility controls pass without this patch.

Registration is blocked: scubashack808/chatwoot-project scratch/woot-board-charting-package-2026-09-14.md identifies bp44/D609 patch registry rows in blueprint.db. That external registry is not available in this checkout. Do not treat this receipt as registration. Need authorized registry access or owner registration before final acceptance/review handoff.

Related work: builds on merged WOOT-1/29/30/31 and WOOT-38 baseline. WOOT-65/PR51 is a profile-only omitted-versus-empty precedent, not a code dependency. WOOT-32/PR28 and WOOT-78/PR60 are not used for this native sandbox test route. No declared blocking branch at implementation start.
