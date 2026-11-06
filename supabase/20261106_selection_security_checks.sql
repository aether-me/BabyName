-- Manual PostgreSQL/Supabase verification for
-- 20261106_secure_selection_progression_FIXED.sql.
-- Run the preflight section BEFORE applying the migration.
-- This script is read-only unless you explicitly uncomment the psql test steps.

-- 1. Preflight: must return zero rows before the unique expression index is created.
select round_id, user_id,
       least(left_name,right_name) as first_name,
       greatest(left_name,right_name) as second_name,
       count(*) as duplicate_count
from public.name_selection_pair_votes
group by round_id,user_id,least(left_name,right_name),greatest(left_name,right_name)
having count(*)>1;

-- 2. After migration: must return zero rows. SELECT policies are expected to remain.
select schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check
from pg_catalog.pg_policies
where schemaname='public'
  and tablename in ('name_selection_rounds','name_selection_votes',
                    'name_selection_pair_votes','name_selection_decisions')
  and cmd in ('INSERT','UPDATE','DELETE','ALL')
order by tablename,policyname;

-- 3. Table privileges: authenticated should have SELECT only; anon/PUBLIC none.
select table_name,grantee,privilege_type
from information_schema.role_table_grants
where table_schema='public'
  and table_name in ('name_selection_rounds','name_selection_votes',
                     'name_selection_pair_votes','name_selection_decisions')
  and grantee in ('anon','authenticated','PUBLIC')
order by table_name,grantee,privilege_type;

-- 4. Function owners, search_path and effective EXECUTE rights.
-- Expected authenticated EXECUTE: selection_member, selection_round_revealed,
-- selection_round_status, record_selection_vote, record_selection_pair_vote,
-- advance_selection_round, create_selection_round, confirm_selection_decision.
-- Expected no authenticated EXECUTE: selection_valid_candidate,
-- selection_round_complete, selection_round_insert_allowed.
select p.proname,
       pg_catalog.pg_get_userbyid(p.proowner) as owner,
       p.proconfig,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in (
    'selection_member','selection_valid_candidate','selection_round_complete',
    'selection_round_revealed','selection_round_status','record_selection_vote',
    'record_selection_pair_vote','advance_selection_round','create_selection_round',
    'confirm_selection_decision','selection_round_insert_allowed'
  )
order by p.proname,pg_catalog.pg_get_function_identity_arguments(p.oid);

-- 5. Inspect function source for row locks. Both record functions and advance
-- should contain FOR UPDATE on name_selection_rounds.
select p.proname, pg_catalog.pg_get_functiondef(p.oid) as definition
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in ('record_selection_vote','record_selection_pair_vote',
                    'advance_selection_round','confirm_selection_decision');

-- 6. Optional manual integration checks (use a disposable test room and two
-- real test auth.users/room_members records; do not substitute production IDs).
-- Run each attempted direct write separately inside a transaction/savepoint;
-- it must fail with insufficient_privilege for authenticated:
--   INSERT INTO public.name_selection_votes(...);
--   UPDATE public.name_selection_votes SET ...;
--   DELETE FROM public.name_selection_votes WHERE ...;
-- Repeat for name_selection_pair_votes and name_selection_decisions.
--
-- RPC checks as authenticated:
--   record_selection_vote rejects a non-candidate and invalid choice.
--   record_selection_pair_vote rejects a non-candidate, same-name pair, and
--     reverse-orientation duplicate (unique violation is acceptable rejection).
--   advance_selection_round rejects calls before both participants finish.
--   confirm_selection_decision rejects a name outside final candidates.
--
-- Concurrency check: in TWO database sessions, call confirm_selection_decision
-- for the same final round at nearly the same time. Same names must converge to
-- is_common=true; different names must remain non-common. Once common, a
-- different later confirmation must fail as locked.
--
-- Concurrency check for votes: prepare both participants with all but one vote.
-- Submit the final votes concurrently. After both commits, any further vote
-- update must fail because selection_round_revealed is true. The row lock on
-- the round serializes these writes with advance_selection_round.
