-- Keywords are optional; when provided, use two to five terms.
alter table public.papers drop constraint papers_submission_contact;
alter table public.papers add constraint papers_submission_contact check (
  status in ('draft', 'revision') or (
    btrim(contact_name) <> '' and btrim(contact_email) <> ''
    and (cardinality(keywords) = 0 or cardinality(keywords) between 2 and 5)
  )
);
