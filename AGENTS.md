# Co-R&BD Conference 2026: agent guide

## Current project

- This repository serves one conference, Co-R&BD Conference 2026. Do not add a conference
  directory, site-request flow, or multi-conference model without a specific requirement.
- The current site is plain HTML, CSS, and browser JavaScript in `site/`. `site/api/` contains
  Vercel Functions. Supabase provides Auth, Postgres, and private Storage. Vercel deploys `site/`
  to `https://co-rnbd.org` from GitHub `main`.
- There is currently no Next.js application, TypeScript setup, `package.json`, or package manager.
  Inspect the repository before introducing any of them. Do not use Next.js, React, or npm
  commands as default instructions.
- Public pages are `site/index.html` and `site/cfp.html`; `site/submission.html` is the
  single-conference author, reviewer, and chair portal. General attendee registration is separate
  and has not been implemented in this repository.
- The conference dates and venue are confirmed in the project content; paper submission dates,
  organizer details, and some program information remain provisional. Preserve the
  confirmed/proposed distinction. Never invent speakers, organizers, deadlines, contact details,
  URLs, or registration links.
- Start with `README.md`, `site/README.md`, and the relevant files under `docs/`. Treat the
  current code, migrations, and connected database as evidence; the documents may lag behind
  deployed behavior.

## Working on a task

1. Read this file and the relevant project documentation. Inspect the affected implementation and
   its dependencies.
2. Check `git status --short --branch` and `git log -1 --oneline`. Preserve all existing user
   changes, including untracked files.
3. Decide the smallest change that satisfies the request. For nontrivial work, state the intended
   behavior, affected files, data or deployment impact, and verification approach briefly.
4. Resolve routine implementation choices from existing behavior and the user's instructions. Ask
   only when missing information would materially change the result or approval is required for a
   consequential action. Prior authorization in the conversation remains valid.
5. Implement, inspect the diff, run checks relevant to the change, and verify the visible behavior
   where possible. Report what was implemented, tested, deployed, and still unverified as distinct
   states.

If bkit tools are available, initialize and inspect the relevant PDCA state. Use
`bkit_pre_write_check` before source-code edits, `bkit_post_write` after significant source
changes, and `bkit_complete_phase` only when that phase actually progressed. Existing feature
plans and designs are in `docs/01-plan/features/` and `docs/02-design/features/`. Do not create a
full new plan for an obvious text correction.

## Git and deployment

- The primary checkout may be dirty or behind `origin/main`. Do not run `git switch main`,
  `git pull`, `git reset`, `git clean`, or checkout commands over unrelated work to begin a task.
- For isolated code work, run `git fetch origin`, then create a separate worktree based on
  `origin/main`. Use a task branch such as `codex/<topic>` in Codex-managed worktrees. Check for
  remote changes again before pushing.
- Keep commits focused and exclude `.env` files, credentials, generated temporary files, unrelated
  assets, and other people's edits. Review `git status`, `git diff --check`, and the staged diff
  before committing.
- A feature branch and pull request are the default route for functional changes. Verify a Vercel
  Preview when available and useful. Documentation-only or urgent fixes may use a shorter route
  when the user authorizes it.
- Do not push or merge directly to `main`, force-push, rewrite shared history, delete remote
  branches, or merge a pull request without authorization for that action. An explicit instruction
  already given in the conversation counts; do not ask for the same approval again. A generic
  request to “push” does not by itself specify a direct push to `main`.
- Before a Preview write test, check whether Preview uses the production Supabase project. If it
  does, avoid test writes to real data; use a safe test environment or a rollback-only database
  check. Build success alone does not prove the flow works.
- After an authorized production deployment, verify the deployed page and affected API/data
  behavior. Clearly distinguish a successful push, Vercel build, and actual production
  verification.

## Conference content and UX

- Keep this a single-conference site. Link users directly to the Co-R&BD 2026 CFP and submission
  portal.
- Preserve the existing visual style and Korean-first presentation. Check mobile and desktop
  layouts, keyboard access, form labels, focus, heading order, alt text, loading, empty, success,
  and error states when relevant.
- Keep provisional dates and placeholders visibly provisional. Do not change confirmed event facts
  without a reliable source or a user instruction. Check Korean and English copies when shared
  facts change.
- Avoid duplicating frequently edited information across pages when an existing structured source
  can serve it. Do not add a CMS or new table solely to avoid a small, stable content edit.
- Optimize images and avoid adding dependencies for tasks the current stack can handle.

## Submission and review model

- `conference_settings` is a single conference-wide settings row. It controls submission, review,
  and final-upload stages, optional deadlines, and the public submission notice. Do not infer that
  a new `conferences` table is needed.
- `profiles` holds member details; `papers` holds manuscripts; `paper_authors` holds author rows;
  `paper_files` holds submission/final PDF versions; `reviews` holds assignments and
  recommendations; `staff_roles` grants chair authority. Read the latest migrations and live
  schema before changing these relationships.
- Authors manage drafts, PDF uploads, submission, revision, and final versions. Reviewers see
  assigned papers, handle conflicts, and submit concise recommendations. The chair controls
  stages, reviewer assignment, and decisions. Keep the review process proportionate to this
  conference; do not copy all CMT roles or features.
- Email/password login is provided. Google and Naver login depend on provider configuration; check
  actual availability before claiming either works. Kakao login is outside the requested scope.
- General attendee registration is not the paper-submission workflow. Design any future
  registration feature separately, with minimum necessary personal data, duplicate handling,
  explicit confirmation behavior, and access controls.

## Supabase, privacy, and security

- Before database changes, inspect the schema, migrations, constraints, grants, RLS policies,
  Storage policies, and affected client code. Represent schema changes in focused, reproducible
  migrations and verify the applied result.
- Enforce ownership and role permissions in Postgres RLS and/or an authorized server boundary.
  Hidden UI controls are never the only authorization check. Validate inputs at the database or
  server boundary as well as in the browser when appropriate.
- `site/api/config.js` sends only client-safe settings to the browser: the Supabase URL,
  publishable key, and Naver availability flag. Never expose service-role or secret keys,
  database passwords, OAuth secrets, or signing keys in public code, responses, logs, or commits.
- Private PDFs and personal profiles must remain limited to their permitted authors, assigned
  reviewers, and/or chair according to the existing policies. Do not use real submissions or
  participant records as disposable test data.
- Treat authentication emails, bulk announcements, uploads, and external API calls as side
  effects. Confirm recipients and environment before bulk communication; do not trigger messages
  to real participants for a routine test.
- Follow the project's privacy policy and data minimization requirements. Do not add phone
  numbers, addresses, or other personal fields without a concrete operational need.
- Never weaken or disable RLS or authentication to work around a failure. Diagnose the permission
  path first.

## Verification that fits this repository

- JavaScript syntax: run `node --check` on changed `.js` files. Check HTML structure, links, and
  IDs when changing markup. Run `git diff --check` on every change.
- Static preview: `python3 -m http.server 8765 --directory site` can verify layout and navigation.
  It does **not** provide Vercel `/api/config`; it cannot prove login, submission, or database
  flows.
- For UI changes, inspect relevant desktop and narrow mobile widths (around 390px), including
  overflow and interactive states. For auth, role, Storage, or API changes, verify the actual
  request → authorization → data → response path in a suitable environment.
- For Supabase changes, query the resulting schema/policies and test allow/deny behavior without
  leaving production test records. Check migrations and deployed state separately.
- Run only checks that exist and address a concrete risk. There is no default npm lint, typecheck,
  test, or build script in the current repository.
- If a check fails, identify whether the change caused it, fix relevant failures, and report
  unrelated failures accurately. Never claim an unrun check passed.

## Approval and completion

- Proceed with reversible, low-impact work authorized by the task. Do not introduce a generic
  approval gate for every file edit, commit, or read-only inspection.
- Obtain explicit authorization before irreversible deletion, destructive production migration,
  broad production data edits, security-reducing changes, credential changes, force-push, or a
  production merge/deployment that the user has not already authorized. Prepare a concrete,
  reviewable result before requesting final approval.
- Before any production-sensitive change, identify affected data and systems, reversibility, and
  rollback approach. A previous explicit approval for the same action remains valid; a new
  materially different action needs its own authorization.
- Finish by stating the changed files or PR, checks performed and outcomes, deployment status if
  applicable, and remaining operational limitations. Do not present pending OAuth provider setup,
  untested registration, or provisional conference dates as complete.
