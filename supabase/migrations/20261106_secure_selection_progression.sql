-- Additive hardening for staged selection. Apply after the prior selection migrations.
-- This migration never deletes user data and keeps the existing SELECT policies.

-- A final pair is unique for one participant even if its names are supplied
-- in the reverse order. Existing duplicate data, if any, is never altered.
-- Fail with an actionable message before attempting the index if old data
-- already contains reverse-orientation duplicates.
do $$
begin
  if exists (
    select 1
    from public.name_selection_pair_votes
    group by round_id, user_id, least(left_name,right_name), greatest(left_name,right_name)
    having count(*) > 1
  ) then
    raise exception 'Cannot create pair uniqueness index: historical reverse-pair duplicates exist. Review them manually; this migration will not delete data.';
  end if;
end;
$$;

create unique index if not exists name_selection_pair_votes_no_reverse
on public.name_selection_pair_votes
  (round_id, user_id, least(left_name,right_name), greatest(left_name,right_name));

-- All helper functions use an empty search_path and explicitly qualified names.
-- auth.uid() still reads the caller JWT under SECURITY DEFINER.
create or replace function public.selection_member(p_round uuid,p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
 select exists(
   select 1 from public.name_selection_rounds r
   join public.room_members m on m.room_id=r.room_id
   where r.id=p_round and m.user_id=p_user and p_user=auth.uid()
 );
$$;

create or replace function public.selection_valid_candidate(p_round uuid,p_name text)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(
   select 1
   from public.name_selection_rounds r
   cross join lateral pg_catalog.jsonb_array_elements(r.candidates) c
   where r.id=p_round and c->>'name'=p_name
 );
$$;

create or replace function public.selection_round_complete(p_round uuid,p_user uuid)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare r public.name_selection_rounds; expected_count integer; actual_count integer;
begin
 select * into r from public.name_selection_rounds where id=p_round;
 if not found then return false; end if;
 expected_count:=case when r.kind='final'
   then pg_catalog.jsonb_array_length(r.candidates)*(pg_catalog.jsonb_array_length(r.candidates)-1)/2
   else pg_catalog.jsonb_array_length(r.candidates) end;
 if r.kind='final' then
   select count(*) into actual_count
   from public.name_selection_pair_votes v
   where v.round_id=p_round and v.user_id=p_user
     and public.selection_valid_candidate(p_round,v.left_name)
     and public.selection_valid_candidate(p_round,v.right_name)
     and v.left_name<>v.right_name;
 else
   select count(*) into actual_count
   from public.name_selection_votes v
   where v.round_id=p_round and v.user_id=p_user
     and public.selection_valid_candidate(p_round,v.name);
 end if;
 return actual_count>=expected_count;
end $$;

create or replace function public.selection_round_revealed(p_round uuid)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.selection_member(p_round,auth.uid()) then return false; end if;
 return (select count(*)=2 and bool_and(public.selection_round_complete(p_round,m.user_id))
         from public.room_members m
         join public.name_selection_rounds r on r.room_id=m.room_id
         where r.id=p_round);
end $$;

create or replace function public.selection_round_status(p_round uuid)
returns table(my_done boolean,partner_done boolean,both_done boolean)
language plpgsql stable security definer set search_path='' as $$
declare other uuid;
begin
 if auth.uid() is null or not public.selection_member(p_round,auth.uid()) then
   raise exception 'not a room member' using errcode='42501';
 end if;
 select m.user_id into other
 from public.room_members m
 join public.name_selection_rounds r on r.room_id=m.room_id
 where r.id=p_round and m.user_id<>auth.uid()
 limit 1;
 my_done:=public.selection_round_complete(p_round,auth.uid());
 partner_done:=coalesce(public.selection_round_complete(p_round,other),false);
 both_done:=my_done and partner_done;
 return next;
end $$;

create or replace function public.record_selection_vote(p_round uuid,p_name text,p_choice smallint)
returns void language plpgsql security definer set search_path='' as $$
declare r public.name_selection_rounds;
begin
 if auth.uid() is null then raise exception 'authentication required' using errcode='28000'; end if;
 -- Serialize vote writes with each other and with advance_selection_round.
 select * into r from public.name_selection_rounds where id=p_round for update;
 if not found or r.kind<>'screen' or not public.selection_member(p_round,auth.uid()) then
   raise exception 'invalid round' using errcode='42501';
 end if;
 if public.selection_round_revealed(p_round) then raise exception 'round is locked' using errcode='42501'; end if;
 if p_choice not in(-1,1) or not public.selection_valid_candidate(p_round,p_name) then
   raise exception 'invalid vote' using errcode='22023';
 end if;
 insert into public.name_selection_votes(round_id,user_id,name,choice,updated_at)
 values(p_round,auth.uid(),p_name,p_choice,pg_catalog.now())
 on conflict(round_id,user_id,name) do update
 set choice=excluded.choice,updated_at=excluded.updated_at;
end $$;

create or replace function public.record_selection_pair_vote(p_round uuid,p_left text,p_right text,p_choice text)
returns void language plpgsql security definer set search_path='' as $$
declare r public.name_selection_rounds;
begin
 if auth.uid() is null then raise exception 'authentication required' using errcode='28000'; end if;
 -- Serialize pair-vote writes with each other and with round advancement.
 select * into r from public.name_selection_rounds where id=p_round for update;
 if not found or r.kind<>'final' or not public.selection_member(p_round,auth.uid()) then
   raise exception 'invalid round' using errcode='42501';
 end if;
 if public.selection_round_revealed(p_round) then raise exception 'round is locked' using errcode='42501'; end if;
 if p_choice not in('left','right') or p_left=p_right
    or not public.selection_valid_candidate(p_round,p_left)
    or not public.selection_valid_candidate(p_round,p_right) then
   raise exception 'invalid pair' using errcode='22023';
 end if;
 insert into public.name_selection_pair_votes(round_id,user_id,left_name,right_name,choice,updated_at)
 values(p_round,auth.uid(),p_left,p_right,p_choice,pg_catalog.now())
 on conflict(round_id,user_id,left_name,right_name) do update
 set choice=excluded.choice,updated_at=excluded.updated_at;
end $$;

create or replace function public.advance_selection_round(p_round uuid)
returns public.name_selection_rounds language plpgsql security definer set search_path='' as $$
declare r public.name_selection_rounds; next_candidates jsonb; next_stage integer;
        next_attempt integer; next_kind text; out_round public.name_selection_rounds;
begin
 if auth.uid() is null then raise exception 'authentication required' using errcode='28000'; end if;
 select * into r from public.name_selection_rounds where id=p_round for update;
 if not found or r.kind<>'screen' or not public.selection_member(p_round,auth.uid())
    or not public.selection_round_revealed(p_round) then
   raise exception 'round cannot advance' using errcode='42501';
 end if;
 if r.stage<3 then
   select coalesce(pg_catalog.jsonb_agg(c),'[]'::jsonb) into next_candidates
   from pg_catalog.jsonb_array_elements(r.candidates) c
   where exists(select 1 from public.name_selection_votes v
                where v.round_id=r.id and v.name=c->>'name' and v.choice=1);
 else
   select coalesce(pg_catalog.jsonb_agg(c),'[]'::jsonb) into next_candidates
   from pg_catalog.jsonb_array_elements(r.candidates) c
   where (select count(*) from public.name_selection_votes v
          where v.round_id=r.id and v.name=c->>'name' and v.choice=1)=2;
 end if;
 if pg_catalog.jsonb_array_length(next_candidates)=0 then
   next_stage:=r.stage; next_attempt:=r.attempt+1; next_kind:='screen'; next_candidates:=r.candidates;
 elsif r.stage>=3 and pg_catalog.jsonb_array_length(next_candidates)<=5 then
   next_stage:=r.stage+1; next_attempt:=1; next_kind:='final';
 else
   next_stage:=r.stage+1; next_attempt:=1; next_kind:='screen';
 end if;
 select * into out_round from public.name_selection_rounds
 where room_id=r.room_id and stage=next_stage and attempt=next_attempt;
 if found then return out_round; end if;
 insert into public.name_selection_rounds(room_id,stage,attempt,kind,candidates,created_by)
 values(r.room_id,next_stage,next_attempt,next_kind,next_candidates,auth.uid())
 returning * into out_round;
 return out_round;
end $$;

-- Only the initial catalogue comes from the client. Every later round is
-- derived from server-side vote history by advance_selection_round.
create or replace function public.create_selection_round(
  p_room_id uuid,p_stage integer,p_attempt integer,p_kind text,p_candidates jsonb
)
returns public.name_selection_rounds language plpgsql security definer set search_path='' as $$
declare created_round public.name_selection_rounds;
begin
 if auth.uid() is null then raise exception 'authentication required' using errcode='28000'; end if;
 if not exists(select 1 from public.room_members m where m.room_id=p_room_id and m.user_id=auth.uid()) then
   raise exception 'not a member of this room' using errcode='42501';
 end if;
 if p_stage<>1 or p_attempt<>1 or p_kind<>'screen' then
   raise exception 'only the initial round may be created directly' using errcode='42501';
 end if;
 if pg_catalog.jsonb_typeof(p_candidates)<>'array'
    or pg_catalog.jsonb_array_length(p_candidates)<1
    or pg_catalog.jsonb_array_length(p_candidates)>150
    or exists(select 1 from pg_catalog.jsonb_array_elements(p_candidates) c
              where pg_catalog.jsonb_typeof(c)<>'object'
                 or pg_catalog.jsonb_typeof(c->'name')<>'string'
                 or pg_catalog.btrim(c->>'name')=''
                 or c->>'name'<>pg_catalog.btrim(c->>'name'))
    or exists(select 1 from pg_catalog.jsonb_array_elements(p_candidates) c
              group by c->>'name' having count(*)>1) then
   raise exception 'invalid candidates' using errcode='22023';
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(p_room_id::text));
 select * into created_round from public.name_selection_rounds
 where room_id=p_room_id order by created_at desc limit 1;
 if found then return created_round; end if;
 insert into public.name_selection_rounds(room_id,stage,attempt,kind,candidates,created_by)
 values(p_room_id,1,1,'screen',p_candidates,auth.uid()) returning * into created_round;
 return created_round;
end $$;

create or replace function public.confirm_selection_decision(p_round uuid,p_name text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.name_selection_rounds; locked_name text; common_name text;
begin
 if auth.uid() is null then raise exception 'authentication required' using errcode='28000'; end if;
 -- Serializes both confirmations for this final round before inspecting or
 -- changing its decisions, eliminating the two-client race.
 select * into r from public.name_selection_rounds where id=p_round for update;
 if not found or r.kind<>'final' or not public.selection_member(p_round,auth.uid()) then
   raise exception 'invalid round' using errcode='42501';
 end if;
 if not public.selection_round_revealed(p_round) then raise exception 'final is not complete' using errcode='42501'; end if;
 if not public.selection_valid_candidate(p_round,p_name) then raise exception 'invalid final candidate' using errcode='22023'; end if;
 select d.name into locked_name from public.name_selection_decisions d
 where d.round_id=p_round group by d.name having count(*)=2 limit 1;
 if found then
   if locked_name<>p_name then raise exception 'common decision is locked' using errcode='42501'; end if;
   return pg_catalog.jsonb_build_object('is_common',true,'name',locked_name);
 end if;
 insert into public.name_selection_decisions(round_id,user_id,name,confirmed_at)
 values(p_round,auth.uid(),p_name,pg_catalog.now())
 on conflict(round_id,user_id) do update set name=excluded.name,confirmed_at=excluded.confirmed_at;
 select d.name into common_name from public.name_selection_decisions d
 where d.round_id=p_round group by d.name having count(*)=2 limit 1;
 return pg_catalog.jsonb_build_object('is_common',common_name is not null,'name',coalesce(common_name,p_name));
end $$;

-- Remove every write-capable policy, regardless of its historical name.
-- A FOR ALL policy also grants SELECT, so preserve its SELECT behavior exactly:
-- command, PERMISSIVE/RESTRICTIVE mode, roles, and USING expression.
do $$
declare
  policy_row record;
  read_expression text;
  role_expression text;
  legacy_read_policy text;
begin
  for policy_row in
    select n.nspname, c.relname, p.polname, p.polcmd, p.polpermissive,
           p.polroles, p.polqual, p.polrelid
    from pg_catalog.pg_policy p
    join pg_catalog.pg_class c on c.oid=p.polrelid
    join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname in (
        'name_selection_rounds',
        'name_selection_votes',
        'name_selection_pair_votes',
        'name_selection_decisions'
      )
      and p.polcmd in ('a','w','d','*')
    order by c.relname, p.polname
  loop
    if policy_row.polcmd='*' then
      read_expression := coalesce(
        pg_catalog.pg_get_expr(policy_row.polqual, policy_row.polrelid),
        'true'
      );

      select pg_catalog.string_agg(
        case when role_oid=0 then 'PUBLIC'
             else pg_catalog.quote_ident(pg_catalog.pg_get_userbyid(role_oid))
        end,
        ', ' order by role_oid
      )
      into role_expression
      from pg_catalog.unnest(policy_row.polroles) as role_list(role_oid);

      if role_expression is null or role_expression='' then
        raise exception 'Could not preserve roles for policy %.%',
          policy_row.relname, policy_row.polname;
      end if;

      legacy_read_policy := 'selection_legacy_read_' ||
        pg_catalog.substr(
          pg_catalog.md5(policy_row.relname || ':' || policy_row.polname),
          1, 24
        );

      execute pg_catalog.format(
        'drop policy if exists %I on %I.%I',
        legacy_read_policy, policy_row.nspname, policy_row.relname
      );
      execute pg_catalog.format(
        'create policy %I on %I.%I as %s for select to %s using (%s)',
        legacy_read_policy,
        policy_row.nspname,
        policy_row.relname,
        case when policy_row.polpermissive then 'PERMISSIVE' else 'RESTRICTIVE' end,
        role_expression,
        read_expression
      );
    end if;

    execute pg_catalog.format(
      'drop policy if exists %I on %I.%I',
      policy_row.polname, policy_row.nspname, policy_row.relname
    );
  end loop;
end;
$$;

revoke all on table public.name_selection_rounds,public.name_selection_votes,
  public.name_selection_pair_votes,public.name_selection_decisions from public,anon,authenticated;
grant select on table public.name_selection_rounds,public.name_selection_votes,
  public.name_selection_pair_votes,public.name_selection_decisions to authenticated;

-- SECURITY DEFINER functions must be database-owned rather than application-owned.
-- The old INSERT policy helper is no longer used after write policies are removed.
alter function public.selection_member(uuid,uuid) owner to postgres;
alter function public.selection_valid_candidate(uuid,text) owner to postgres;
alter function public.selection_round_complete(uuid,uuid) owner to postgres;
alter function public.selection_round_revealed(uuid) owner to postgres;
alter function public.selection_round_status(uuid) owner to postgres;
alter function public.record_selection_vote(uuid,text,smallint) owner to postgres;
alter function public.record_selection_pair_vote(uuid,text,text,text) owner to postgres;
alter function public.advance_selection_round(uuid) owner to postgres;
alter function public.create_selection_round(uuid,integer,integer,text,jsonb) owner to postgres;
alter function public.confirm_selection_decision(uuid,text) owner to postgres;
alter function public.selection_round_insert_allowed(uuid,uuid) owner to postgres;

-- Keep the legacy helper inert and safe even if an old policy or client once
-- referenced it. It is not needed by the new RPC-only write path.
alter function public.selection_round_insert_allowed(uuid,uuid) set search_path='';
revoke all on function public.selection_round_insert_allowed(uuid,uuid) from public,anon,authenticated;

-- Reset all API-role grants first. Only the explicitly listed client RPCs and
-- policy helper functions are executable by authenticated users.
revoke all on function public.selection_member(uuid,uuid) from public,anon,authenticated;
revoke all on function public.selection_valid_candidate(uuid,text) from public,anon,authenticated;
revoke all on function public.selection_round_complete(uuid,uuid) from public,anon,authenticated;
revoke all on function public.selection_round_revealed(uuid) from public,anon,authenticated;
revoke all on function public.selection_round_status(uuid) from public,anon,authenticated;
revoke all on function public.record_selection_vote(uuid,text,smallint) from public,anon,authenticated;
revoke all on function public.record_selection_pair_vote(uuid,text,text,text) from public,anon,authenticated;
revoke all on function public.advance_selection_round(uuid) from public,anon,authenticated;
revoke all on function public.create_selection_round(uuid,integer,integer,text,jsonb) from public,anon,authenticated;
revoke all on function public.confirm_selection_decision(uuid,text) from public,anon,authenticated;

grant execute on function public.selection_round_status(uuid) to authenticated;
grant execute on function public.selection_member(uuid,uuid) to authenticated;
grant execute on function public.selection_round_revealed(uuid) to authenticated;
grant execute on function public.record_selection_vote(uuid,text,smallint) to authenticated;
grant execute on function public.record_selection_pair_vote(uuid,text,text,text) to authenticated;
grant execute on function public.advance_selection_round(uuid) to authenticated;
grant execute on function public.create_selection_round(uuid,integer,integer,text,jsonb) to authenticated;
grant execute on function public.confirm_selection_decision(uuid,text) to authenticated;
