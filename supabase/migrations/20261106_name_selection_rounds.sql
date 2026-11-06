-- Apply manually in Supabase SQL Editor. Additive; does not modify legacy votes.
create table if not exists public.name_selection_rounds (
 id uuid primary key default gen_random_uuid(), room_id uuid not null references public.rooms(id) on delete cascade,
 stage integer not null check(stage>=1), attempt integer not null default 1 check(attempt>=1),
 kind text not null check(kind in('screen','final')), candidates jsonb not null check(jsonb_typeof(candidates)='array'),
 created_by uuid not null references auth.users(id), created_at timestamptz not null default now(), unique(room_id,stage,attempt)
);
create table if not exists public.name_selection_votes (
 round_id uuid not null references public.name_selection_rounds(id) on delete cascade, user_id uuid not null references auth.users(id),
 name text not null, choice smallint not null check(choice in(-1,1)), updated_at timestamptz not null default now(), primary key(round_id,user_id,name)
);
create table if not exists public.name_selection_pair_votes (
 round_id uuid not null references public.name_selection_rounds(id) on delete cascade, user_id uuid not null references auth.users(id),
 left_name text not null, right_name text not null, choice text not null check(choice in('left','right')),
 updated_at timestamptz not null default now(), primary key(round_id,user_id,left_name,right_name)
);
create table if not exists public.name_selection_decisions (
 round_id uuid not null references public.name_selection_rounds(id) on delete cascade, user_id uuid not null references auth.users(id),
 name text not null, confirmed_at timestamptz not null default now(), primary key(round_id,user_id)
);
create or replace function public.selection_member(p_round uuid,p_user uuid default auth.uid()) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from name_selection_rounds r join room_members m on m.room_id=r.room_id where r.id=p_round and m.user_id=p_user);
$$;
create or replace function public.selection_round_complete(p_round uuid,p_user uuid) returns boolean language plpgsql stable security definer set search_path=public as $$
declare k text; n integer; expected integer; actual integer;
begin select kind,jsonb_array_length(candidates) into k,n from name_selection_rounds where id=p_round; if not found then return false; end if;
 expected:=case when k='final' then n*(n-1)/2 else n end;
 if k='final' then select count(*) into actual from name_selection_pair_votes where round_id=p_round and user_id=p_user; else select count(*) into actual from name_selection_votes where round_id=p_round and user_id=p_user; end if;
 return actual>=expected;
end $$;
create or replace function public.selection_round_revealed(p_round uuid) returns boolean language sql stable security definer set search_path=public as $$
 select count(*)=2 and bool_and(selection_round_complete(p_round,m.user_id)) from room_members m join name_selection_rounds r on r.room_id=m.room_id where r.id=p_round;
$$;
create or replace function public.selection_round_status(p_round uuid) returns table(my_done boolean,partner_done boolean,both_done boolean) language plpgsql stable security definer set search_path=public as $$
declare other uuid; begin if not selection_member(p_round,auth.uid()) then raise exception 'not a room member'; end if;
 select m.user_id into other from room_members m join name_selection_rounds r on r.room_id=m.room_id where r.id=p_round and m.user_id<>auth.uid() limit 1;
 my_done:=selection_round_complete(p_round,auth.uid()); partner_done:=coalesce(selection_round_complete(p_round,other),false); both_done:=my_done and partner_done; return next; end $$;
alter table public.name_selection_rounds enable row level security;
alter table public.name_selection_votes enable row level security;
alter table public.name_selection_pair_votes enable row level security;
alter table public.name_selection_decisions enable row level security;
create policy "selection rounds room read" on public.name_selection_rounds for select to authenticated using(selection_member(id));
create policy "selection rounds member create" on public.name_selection_rounds for insert to authenticated with check(created_by=auth.uid() and exists(select 1 from room_members m where m.room_id=name_selection_rounds.room_id and m.user_id=auth.uid()));
create policy "selection vote guarded read" on public.name_selection_votes for select to authenticated using(user_id=auth.uid() or selection_round_revealed(round_id));
create policy "selection vote own insert" on public.name_selection_votes for insert to authenticated with check(user_id=auth.uid() and selection_member(round_id));
create policy "selection vote own mutable" on public.name_selection_votes for update to authenticated using(user_id=auth.uid() and selection_member(round_id) and not selection_round_revealed(round_id)) with check(user_id=auth.uid() and selection_member(round_id));
create policy "pair vote guarded read" on public.name_selection_pair_votes for select to authenticated using(user_id=auth.uid() or selection_round_revealed(round_id));
create policy "pair vote own insert" on public.name_selection_pair_votes for insert to authenticated with check(user_id=auth.uid() and selection_member(round_id));
create policy "pair vote own mutable" on public.name_selection_pair_votes for update to authenticated using(user_id=auth.uid() and selection_member(round_id) and not selection_round_revealed(round_id)) with check(user_id=auth.uid() and selection_member(round_id));
create policy "decision guarded read" on public.name_selection_decisions for select to authenticated using(user_id=auth.uid() or selection_round_revealed(round_id));
create policy "decision own write" on public.name_selection_decisions for all to authenticated using(user_id=auth.uid() and selection_member(round_id)) with check(user_id=auth.uid() and selection_member(round_id));
grant execute on function public.selection_round_status(uuid) to authenticated;
