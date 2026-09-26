# Login

A synthetic agent can sign in, reject an incorrect password and leave through the visible profile menu.

## Sub-features

- login-reject: wrong password leaves the user signed out with an error.
- login-success: correct synthetic credentials open the account and show Dummy Agent.
- login-logout: Log out returns to the login form.

## How to get to it (user POV)

- Open http://127.0.0.1:3001/app/login in the authorized dummy tab.
- If signed in, open Dummy Agent's profile menu and choose Log out.

## Driving it with browser-harness

Preconditions: Doctor passes, the exact Profile 14 tab is identified and the pilot owns the runtime lease. Only private dummy credentials are allowed. Real authentication, MFA or consent requests stop this recipe.

- **Open.** The pilot clicks the visible button containing agent@chatwoot-dummy.test, then Log out. Observe input[name="email_address"] and input[name="password"].
- **Reject.** Type synthetic email and deliberately wrong dummy password; click button[type="submit"]. Require the visible Invalid login credentials error and capture the signed-out state.
- **Sign in.** Replace only the synthetic password with DUMMY_PASSWORD from the private runtime file. Click submit. Require the visible agent@chatwoot-dummy.test profile and capture the inbox.
- **Run.** From the repo root: python3 -B .cursor/skills/verify-chatwoot/scripts/verify.py pilot --target-id "$CHATWOOT_TARGET_ID" --restart-existing. Concrete driver calls are in scripts/mail_flow.py. Every click uses a uniquely observed visible control and click_at_xy; typing uses fill_input.
- **Proof.** Read actions.jsonl and 01-login/02-rejected/03-inbox screenshot, text and accessibility artifacts. Credential values never enter evidence.

## Gotchas

- Existing sessions do not prove new login; the pilot explicitly logs out first.
- Compilation can briefly show a blank page. Wait for a concrete rendered condition within the bounded budget.
- Multiple dummy tabs can exist; exact target identity determines authority.
- Record the failed login before the valid attempt so success cannot conceal a broken negative control.
