# Co-R&BD Conference: agent guide

## Current project

- This repository serves one recurring Co-R&BD conference, starting with the 2026 edition.
  Annual editions share one site and account system. Do not add an unrelated conference directory
  or site-request flow.
- The site is a Next.js App Router and TypeScript project rooted at `site/`. Repository-controlled
  page bodies are in `site/content/` and existing DOM clients are in `site/public/legacy/` during
  the migration. TypeScript Route Handlers are in `site/app/api/`. Supabase provides Auth, Postgres,
  and private Storage. Vercel deploys `site/` to `https://co-rnbd.org` from GitHub `main`.
- Use `npm ci`, `npm run typecheck`, and `npm run build` in `site/` for dependency, type, and
  production build checks. Keep the lockfile pinned and avoid adding packages without need.
- `site/content/index.html` and `site/content/cfp.html` preserve the detailed 2026 content.
  `/edition.html` presents later active years and published archive records; `/archive.html` lists
  past years. `/submission.html` is the author, reviewer, and chair portal. General attendee
  registration is separate at `/registration.html`. Preserve these URLs and their DOM IDs.
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

- Keep one recurring-conference site with the current edition one click away. The 2026 editorial
  CFP is specific to 2026; later years require newly approved call text before linking to a CFP.
  Never silently reuse an old year's dates or submission terms.
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

- `conference_editions` identifies each year and its draft/current/archived state.
  `conference_settings` has one row per edition and controls submission, review, final-upload,
  and registration stages. Annual records carry `edition_year`; authors, files, and reviews inherit
  their year from `papers`. Keep archived private data private and frozen. Publish archive metadata
  only after the chair reviews it.
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
- General attendee registration is separate from paper submission. Preserve the minimum-personal-data
  approach, per-year duplicate handling, explicit confirmation, and access controls.

## Supabase, privacy, and security

- Before database changes, inspect the schema, migrations, constraints, grants, RLS policies,
  Storage policies, and affected client code. Represent schema changes in focused, reproducible
  migrations and verify the applied result.
- Enforce ownership and role permissions in Postgres RLS and/or an authorized server boundary.
  Hidden UI controls are never the only authorization check. Validate inputs at the database or
  server boundary as well as in the browser when appropriate.
- `site/app/api/config/route.ts` sends only client-safe settings to the browser: the Supabase URL,
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

- Run `npm run typecheck` and `npm run build` in `site/`. Run `node --check` on changed legacy
  `.js` files. Check HTML structure, links, and IDs when changing content. Run `git diff --check`.
- Local preview: `npm run dev` in `site/` serves the Next.js pages and API routes. Without local
  Supabase environment settings it cannot prove login, submission, or database flows.
- For UI changes, inspect relevant desktop and narrow mobile widths (around 390px), including
  overflow and interactive states. For auth, role, Storage, or API changes, verify the actual
  request → authorization → data → response path in a suitable environment.
- For Supabase changes, query the resulting schema/policies and test allow/deny behavior without
  leaving production test records. Check migrations and deployed state separately.
- Run checks that address a concrete risk. The project has typecheck and build scripts; there is
  no general test or lint script.
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
