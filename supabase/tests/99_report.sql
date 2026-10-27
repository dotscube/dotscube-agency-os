\set ON_ERROR_STOP 1
-- =================== REPORT ===================
\o
\pset format aligned
select n, case when ok then 'ok' else 'FAIL' end as result, name, case when not ok then detail end as detail
from tst.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from tst.results;
do $$ begin
  if exists (select 1 from tst.results where not ok) then raise exception 'DATABASE TESTS FAILED'; end if;
end $$;
