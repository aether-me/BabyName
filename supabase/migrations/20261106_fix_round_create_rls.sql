-- Apply after 20261106_name_selection_rounds.sql.
-- The existing database has ambiguous selection_is_room_member overloads;
-- this migration deliberately does not call or remove them.

create or replace function public.selection_round_insert_allowed(
  p_room_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_user_id = auth.uid()
     and exists (
       select 1
       from public.room_members m
       where m.room_id = p_room_id
         and m.user_id = p_user_id
     );
$$;

revoke all on function public.selection_round_insert_allowed(uuid, uuid) from public;
grant execute on function public.selection_round_insert_allowed(uuid, uuid) to authenticated;

drop policy if exists "selection rounds member create" on public.name_selection_rounds;

create policy "selection rounds member create"
on public.name_selection_rounds
for insert
to authenticated
with check (
  created_by = auth.uid()
  and public.selection_round_insert_allowed(room_id, auth.uid())
);
