-- Keep the edition identity and previously issued document snapshots intact.
update public.conference_editions
set title = 'TVET Co-R&BD Conference 2026'
where year = 2026
  and status = 'current'
  and title in ('T-VET Co-R&BD Conference 2026', 'Co-R&BD Conference 2026');
