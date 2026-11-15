alter table public.paper_authors
  add column note text check (note is null or char_length(note) <= 200);
