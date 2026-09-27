# Conference operations — plan

## Purpose

Add attendee registration, a published program, and chair-managed speakers/sessions to the existing single-conference site. Keep paper submission and general attendance separate.

## Scope and decisions

- A signed-in member applies once for the 17th, 18th, or both days. The member can cancel; the chair confirms applications and records arrival. No fee or payment flow until the organizer confirms a fee policy.
- The chair maintains speaker profiles and sessions as drafts, then explicitly publishes them. The public program reads only published rows. No named person, room, or detailed schedule is seeded without confirmation.
- Reuse Supabase Auth and the existing chair role. Minimize personal data: registration references the existing profile rather than copying name/email; collect only attendee category and days.
- Show registration, program, and management links on the site and portal. Work on desktop and narrow mobile screens.

## Success criteria

- An anonymous visitor can read published sessions and speakers, but cannot read registrations or drafts.
- A member can submit exactly one application, view its state, and cancel it only while registration is open.
- Only the chair can confirm/check in attendees and manage program records. Database constraints and RLS enforce these boundaries.
- The site distinguishes an application from a confirmed place, and empty program data from a confirmed schedule.

## References

- [IEIE 2025 fall registration](https://conf.theieie.org/2025f/pages/conference_reginfo.vm)
- [IEIE 2025 fall program](https://conf.theieie.org/2025f/pages/programs.vm)
- [KICS 2025 fall program](https://conf.kics.or.kr/2025f/downloadProgram?type=program)
- [Supabase API security](https://supabase.com/docs/guides/api/securing-your-api)

## Rollout

Implement a versioned migration and static pages on a feature branch. Verify syntax, UI, schema/RLS, and a Vercel Preview. Production merge and migration remain a separate rollout decision.
