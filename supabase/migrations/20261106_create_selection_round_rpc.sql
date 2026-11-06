-- Additive RPC for safe round creation. Run manually in Supabase SQL Editor.
create or replace function public.create_selection_round(
  p_room_id uuid,
  p_stage integer,
  p_attempt integer,
  p_kind text,
  p_candidates jsonb
)
returns public.name_selection_rounds
language plpgsql
security definer
set search_path = public
as $$
declare
  created_round public.name_selection_rounds;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not exists (
    select 1 from public.room_members m
    where m.room_id = p_room_id and m.user_id = auth.uid()
  ) then
    raise exception 'not a member of this room' using errcode = '42501';
  end if;
  if p_stage < 1 or p_stage > 100 then
    raise exception 'invalid stage' using errcode = '22023';
  end if;
  if p_attempt < 1 or p_attempt > 100 then
    raise exception 'invalid attempt' using errcode = '22023';
  end if;
  if p_kind not in ('screen', 'final') then
    raise exception 'invalid round kind' using errcode = '22023';
  end if;
  if jsonb_typeof(p_candidates) <> 'array'
     or jsonb_array_length(p_candidates) < 1
     or jsonb_array_length(p_candidates) > 150
     or exists (
       select 1 from jsonb_array_elements(p_candidates) c
       where jsonb_typeof(c) <> 'object'
          or coalesce(nullif(trim(c->>'name'), ''), '') = ''
     ) then
    raise exception 'invalid candidates' using errcode = '22023';
  end if;
  insert into public.name_selection_rounds
    (room_id, stage, attempt, kind, candidates, created_by)
  values
    (p_room_id, p_stage, p_attempt, p_kind, p_candidates, auth.uid())
  returning * into created_round;
  return created_round;
end;
$$;

revoke all on function public.create_selection_round(uuid, integer, integer, text, jsonb) from public;
revoke all on function public.create_selection_round(uuid, integer, integer, text, jsonb) from anon;
grant execute on function public.create_selection_round(uuid, integer, integer, text, jsonb) to authenticated;
