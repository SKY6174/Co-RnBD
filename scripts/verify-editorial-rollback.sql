-- Run only against the explicitly selected conference DB after roster setup.
-- Synthetic submitted-paper fixture; every paper/review/audit change is rolled back.
-- PDF upload and browser behavior are verified separately in the disposable local E2E.
begin;
create temporary table editorial_fixture on commit drop as
select gen_random_uuid() as paper_id,
 (select id from auth.users where email='song.kyoung.young@gmail.com' and email_confirmed_at is not null) as chief,
 (select id from auth.users where email='uc.thomas78@gmail.com' and email_confirmed_at is not null) as reviewer1,
 (select id from auth.users where email='thomas78.song@gmail.com' and email_confirmed_at is not null) as reviewer2;
grant select on editorial_fixture to authenticated;
do $$ begin
 if exists(select 1 from editorial_fixture where chief is null or reviewer1 is null or reviewer2 is null) then
   raise exception 'The three verified test accounts are required';
 end if;
end $$;
insert into public.papers(id,owner_id,edition_year,title,abstract,track,paper_type,preferred_presentation,status,submitted_at,contact_name,contact_email)
select paper_id,chief,app_private.current_edition_year(),'[ROLLBACK TEST ONLY] 분야별 편집위원 심사',
 '실제 논문과 개인정보를 포함하지 않는 트랜잭션 롤백 전용 합성 원고입니다.',
 'master_eng','research','oral','submitted',clock_timestamp(),'합성 저자','song.kyoung.young@gmail.com' from editorial_fixture;
insert into public.paper_authors(paper_id,sort_order,full_name,affiliation,email)
select paper_id,1,'합성 저자','롤백 전용 합성 기관','song.kyoung.young@gmail.com' from editorial_fixture;
-- The operational setting is restored even if it was previously closed.
update public.conference_settings set reviews_open=true,review_deadline=null where edition_year=app_private.current_edition_year();
set local role authenticated;
select set_config('request.jwt.claim.sub',(select chief::text from editorial_fixture),true);
select public.chair_assign_reviewer(paper_id,reviewer1) from editorial_fixture;
select public.chair_assign_reviewer(paper_id,reviewer2) from editorial_fixture;
do $$ begin
 if exists(select 1 from public.author_review_feedback((select paper_id from editorial_fixture))) then
   raise exception 'Unpublished reviews leaked';
 end if;
end $$;
select set_config('request.jwt.claim.sub',(select reviewer1::text from editorial_fixture),true);
update public.reviews set review_state='submitted',recommendation='revise',comments='롤백 전용 심사: 방법과 검증 결과를 보완해 주세요.',conflict_confirmed=true
 where paper_id=(select paper_id from editorial_fixture) and reviewer_id=auth.uid();
select set_config('request.jwt.claim.sub',(select reviewer2::text from editorial_fixture),true);
update public.reviews set review_state='submitted',recommendation='accept',comments='롤백 전용 심사: 연구 결과와 활용 가능성을 확인했습니다.',conflict_confirmed=true
 where paper_id=(select paper_id from editorial_fixture) and reviewer_id=auth.uid();
-- AE2 is a reviewer on this paper, but only AE1 manages the master_eng field.
do $$ declare p public.papers; snap jsonb;
begin
 select * into p from public.papers where id=(select paper_id from editorial_fixture);
 begin
   perform public.chair_publish_decision(p.id,'revision','분야 권한 차단 검증',null,null,'',p.updated_at,'[]'::jsonb);
   raise exception 'Wrong field editor was allowed';
 exception when raise_exception then
   if sqlerrm<>'Chair permission required' then raise; end if;
 end;
end $$;
select set_config('request.jwt.claim.sub',(select reviewer1::text from editorial_fixture),true);
do $$ declare p public.papers; snap jsonb; changed integer;
begin
 select * into p from public.papers where id=(select paper_id from editorial_fixture);
 select jsonb_agg(to_jsonb(r) order by r.id) into snap from public.reviews r where r.paper_id=p.id and r.manuscript_submitted_at=p.submitted_at;
 if jsonb_array_length(snap)<>2 then raise exception 'Both reviewer submissions must be visible to AE1'; end if;
 update public.papers set title='FORGED' where id=p.id;
 get diagnostics changed=row_count;
 if changed<>0 then raise exception 'Editor can directly edit paper content'; end if;
 update public.conference_settings set submissions_open=false where edition_year=p.edition_year;
 get diagnostics changed=row_count;
 if changed<>0 then raise exception 'Editor can change operational settings'; end if;
 perform public.chair_publish_decision(p.id,'revision','합성 AE 판정: 수정본을 제출해 주세요.',null,null,'',p.updated_at,snap);
 if not exists(select 1 from public.papers where id=p.id and status='revision' and decided_by=auth.uid()) then
   raise exception 'Editor decision was not persisted';
 end if;
end $$;
select set_config('request.jwt.claim.sub',(select chief::text from editorial_fixture),true);
do $$ declare n integer;
begin
 select count(*) into n from public.author_review_feedback((select paper_id from editorial_fixture));
 if n<>2 then raise exception 'Author must receive two published reviews'; end if;
end $$;
-- A dual-role editor cannot bypass their own declared review conflict.
update public.papers set status='under_review' where id=(select paper_id from editorial_fixture);
select set_config('request.jwt.claim.sub',(select reviewer1::text from editorial_fixture),true);
update public.reviews set review_state='declined',decline_reason='롤백 테스트: 공동 과제 이해관계로 심사를 거절합니다.'
 where paper_id=(select paper_id from editorial_fixture) and reviewer_id=auth.uid();
do $$ begin
 if exists(select 1 from public.papers where id=(select paper_id from editorial_fixture)) then
   raise exception 'A conflicted dual-role editor can still read the paper';
 end if;
 begin
   perform public.chair_publish_decision((select paper_id from editorial_fixture),'accepted','이해관계 우회 검증',null,null,'',null,'[]'::jsonb);
   raise exception 'A conflicted dual-role editor can still publish';
 exception when raise_exception then
   if sqlerrm<>'Chair permission required' then raise; end if;
 end;
end $$;
rollback;
select 'PASS: chief assignment, two real reviewer roles, AE field boundary, decision publication, author feedback, dual-role declared conflict; all synthetic data rolled back' as verification;
