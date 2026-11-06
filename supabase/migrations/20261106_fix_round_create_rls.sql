-- Apply manually after 20261106_name_selection_rounds.sql.
-- Fixes only INSERT authorization for name_selection_rounds.
create or replace function public.selection_is_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.room_members m
    where m.room_id = p_room_id and m.user_id = auth.uid()
  );
$$;

alter function public.selection_is_room_member(uuid) owner to postgres;
revoke all on function public.selection_is_room_member(uuid) from public;
grant execute on function public.selection_is_room_member(uuid) to authenticated;

drop policy if exists "selection rounds member create" on public.name_selection_rounds;
create policy "selection rounds member create"
on public.name_selection_rounds
for insert
to authenticated
with check (
  created_by = auth.uid()
  and public.selection_is_room_member(room_id)
);
