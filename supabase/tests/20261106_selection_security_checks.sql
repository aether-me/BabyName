-- Manual PostgreSQL/Supabase verification scenario; DO NOT run against
-- production data. Use a disposable test room and run the whole write section
-- in psql so ROLLBACK removes every test row.

-- Read-only structural checks after applying the migration.
-- Run this preflight first: it must return no rows before creating the
-- order-independent unique index. The migration deliberately does not delete
-- historical data to make this condition true.
select round_id,user_id,least(left_name,right_name) as first_name,
       greatest(left_name,right_name) as second_name,count(*) as duplicate_count
from public.name_selection_pair_votes
group by round_id,user_id,least(left_name,right_name),greatest(left_name,right_name)
having count(*)>1;

select schemaname,tablename,policyname,cmd,roles
from pg_policies
where schemaname='public'
  and tablename in ('name_selection_rounds','name_selection_votes','name_selection_pair_votes','name_selection_decisions')
order by tablename,policyname;

select table_name,grantee,privilege_type
from information_schema.role_table_grants
where table_schema='public'
  and table_name in ('name_selection_rounds','name_selection_votes','name_selection_pair_votes','name_selection_decisions')
  and grantee in ('anon','authenticated','PUBLIC')
order by table_name,grantee,privilege_type;

select p.proname,pg_get_userbyid(p.proowner) as owner,p.proconfig,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
  'selection_member','selection_valid_candidate','selection_round_complete',
  'selection_round_revealed','selection_round_status','record_selection_vote',
  'record_selection_pair_vote','advance_selection_round','create_selection_round',
  'confirm_selection_decision'
)
order by p.proname,pg_get_function_identity_arguments(p.oid);

-- psql-only write checks. Provide test-only IDs and names, then execute as one
-- transaction. Replace values after the colon; do not run this block on live data.
-- \set user_id '00000000-0000-0000-0000-000000000000'
-- \set round_id '00000000-0000-0000-0000-000000000000'
-- \set room_id '00000000-0000-0000-0000-000000000000'
-- \set candidate 'Тест'
-- begin;
-- set local role authenticated;
-- select set_config('request.jwt.claim.sub', :'user_id', true);
--
-- -- Each direct write must fail because authenticated has SELECT only.
-- insert into public.name_selection_votes(round_id,user_id,name,choice)
-- values(:'round_id',:'user_id',:'candidate',1);
-- update public.name_selection_votes set choice=-1 where round_id=:'round_id';
-- delete from public.name_selection_votes where round_id=:'round_id';
--
-- -- RPC must reject duplicate/invalid initial candidates.
-- select public.create_selection_round(:'room_id',1,1,'screen',
--   '[{"name":"А"},{"name":"А"}]'::jsonb);
-- select public.create_selection_round(:'room_id',1,1,'screen',
--   '[{"name":" "}]'::jsonb);
--
-- -- In two psql sessions, run confirm_selection_decision concurrently with the
-- -- same p_round. Equal names must return is_common=true; different names must
-- -- both return is_common=false. A later different name must raise "locked".
-- rollback;
