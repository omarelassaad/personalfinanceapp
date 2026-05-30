-- WealthTrackr — Supabase setup
-- Safe to re-run: uses IF NOT EXISTS and drops policies before recreating.
-- Run the entire file in Supabase SQL Editor.

-- ─── 0. Grants (ensure authenticated role can access all tables) ─────────────
grant usage on schema public to authenticated, anon;
grant all on all tables    in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

-- ─── 1. Base tables (no dependencies) ────────────────────────────────────────

create table if not exists public.households (
  id         uuid default gen_random_uuid() primary key,
  name       text not null default 'My Household',
  created_at timestamptz default now()
);
alter table public.households enable row level security;
drop policy if exists "households_insert" on public.households;
drop policy if exists "households_select" on public.households;
drop policy if exists "households_update" on public.households;
-- Any signed-in user may create a household
create policy "households_insert" on public.households
  for insert with check (true);
-- Users can view & update their own household (policy evaluated after member row exists)
create policy "households_select" on public.households
  for select using (id = public.get_my_household_id());
create policy "households_update" on public.households
  for update using (id = public.get_my_household_id());

create table if not exists public.household_members (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  household_id uuid not null references public.households(id) on delete cascade,
  role         text not null default 'member',
  joined_at    timestamptz default now()
);
alter table public.household_members enable row level security;

create table if not exists public.household_invites (
  code         text primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  created_by   uuid not null references auth.users(id),
  expires_at   timestamptz not null default (now() + interval '24 hours')
);
alter table public.household_invites enable row level security;

create table if not exists public.household_settings (
  household_id uuid primary key references public.households(id) on delete cascade,
  tags     jsonb default '["Common","Travel","Adam","Zayn","Other"]'::jsonb,
  sub_cats jsonb default '["Dining","Groceries","Transport","Insurance","Recreation","Shopping","Accommodation","Fuel","Pharmacy","Other"]'::jsonb,
  updated_at timestamptz default now()
);
alter table public.household_settings enable row level security;

-- ─── 2. Functions (depend on household_members existing) ─────────────────────

create or replace function public.get_my_household_id()
returns uuid language sql stable security definer as $$
  select household_id from public.household_members where user_id = auth.uid() limit 1
$$;

create or replace function public.create_household_invite()
returns text language plpgsql security definer as $$
declare
  v_household_id uuid;
  v_code text;
begin
  select household_id into v_household_id
    from public.household_members where user_id = auth.uid();
  if not found then raise exception 'No household found for user'; end if;

  v_code := upper(substring(md5(random()::text || clock_timestamp()::text), 1, 6));

  insert into public.household_invites(code, household_id, created_by)
    values (v_code, v_household_id, auth.uid());

  return v_code;
end;
$$;

create or replace function public.join_household(invite_code text)
returns uuid language plpgsql security definer as $$
declare
  v_invite        record;
  v_old_household uuid;
  v_new_household uuid;
begin
  select * into v_invite from public.household_invites
    where code = upper(invite_code) and expires_at > now();
  if not found then raise exception 'Invalid or expired invite code'; end if;

  select household_id into v_old_household
    from public.household_members where user_id = auth.uid();

  v_new_household := v_invite.household_id;
  if v_old_household = v_new_household then
    raise exception 'You are already in this household';
  end if;

  update public.transactions  set household_id = v_new_household where household_id = v_old_household;
  update public.cycles        set household_id = v_new_household where household_id = v_old_household;
  update public.loaded_files  set household_id = v_new_household where household_id = v_old_household;
  update public.nw_snapshots  set household_id = v_new_household where household_id = v_old_household;

  update public.household_members
    set household_id = v_new_household where user_id = auth.uid();

  delete from public.households where id = v_old_household
    and not exists (select 1 from public.household_members where household_id = v_old_household);

  delete from public.household_invites where code = upper(invite_code);

  return v_new_household;
end;
$$;

-- ─── 3. RLS policies on household tables ─────────────────────────────────────

drop policy if exists "own_membership"         on public.household_members;
drop policy if exists "view_household_members" on public.household_members;
create policy "own_membership" on public.household_members
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "view_household_members" on public.household_members
  for select using (household_id = public.get_my_household_id());

drop policy if exists "read_invites"   on public.household_invites;
drop policy if exists "manage_invites" on public.household_invites;
create policy "read_invites"   on public.household_invites for select using (true);
create policy "manage_invites" on public.household_invites
  for all using (created_by = auth.uid()) with check (created_by = auth.uid());

drop policy if exists "household_settings_access" on public.household_settings;
create policy "household_settings_access" on public.household_settings
  for all using (household_id = public.get_my_household_id())
  with check (household_id = public.get_my_household_id());

-- ─── 4. Data tables ───────────────────────────────────────────────────────────

create table if not exists public.transactions (
  id           text        not null,
  user_id      uuid        not null references auth.users(id) on delete cascade,
  household_id uuid        references public.households(id),
  cycle_id     uuid,
  date         text,
  description  text,
  amount       numeric(12,2),
  card         text,
  tag          text,
  sub          text,
  created_at   timestamptz default now(),
  primary key (id, user_id)
);
alter table public.transactions add column if not exists household_id uuid references public.households(id);
alter table public.transactions add column if not exists cycle_id uuid;
alter table public.transactions enable row level security;
drop policy if exists "users_own_transactions" on public.transactions;
drop policy if exists "household_transactions"  on public.transactions;
create policy "household_transactions" on public.transactions
  for all using (
    household_id = public.get_my_household_id()
    or (household_id is null and user_id = auth.uid())
  ) with check (household_id = public.get_my_household_id());

create table if not exists public.loaded_files (
  id           uuid default gen_random_uuid() primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  household_id uuid references public.households(id),
  cycle_id     uuid,
  name         text not null,
  card_id      text,
  created_at   timestamptz default now()
);
alter table public.loaded_files add column if not exists household_id uuid references public.households(id);
alter table public.loaded_files add column if not exists cycle_id uuid;
alter table public.loaded_files enable row level security;
drop policy if exists "users_own_files" on public.loaded_files;
drop policy if exists "household_files" on public.loaded_files;
create policy "household_files" on public.loaded_files
  for all using (
    household_id = public.get_my_household_id()
    or (household_id is null and user_id = auth.uid())
  ) with check (household_id = public.get_my_household_id());
alter table public.loaded_files drop constraint if exists loaded_files_user_id_name_key;
alter table public.loaded_files drop constraint if exists loaded_files_user_id_cycle_id_name_key;
alter table public.loaded_files drop constraint if exists loaded_files_household_id_cycle_id_name_key;
alter table public.loaded_files add constraint loaded_files_household_id_cycle_id_name_key
  unique (household_id, cycle_id, name);

create table if not exists public.cycles (
  id           uuid default gen_random_uuid() primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  household_id uuid references public.households(id),
  name         text not null,
  created_at   timestamptz default now()
);
alter table public.cycles add column if not exists household_id uuid references public.households(id);
alter table public.cycles enable row level security;
drop policy if exists "users_own_cycles" on public.cycles;
drop policy if exists "household_cycles" on public.cycles;
create policy "household_cycles" on public.cycles
  for all using (
    household_id = public.get_my_household_id()
    or (household_id is null and user_id = auth.uid())
  ) with check (household_id = public.get_my_household_id());

create table if not exists public.nw_snapshots (
  id           uuid default gen_random_uuid() primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  household_id uuid references public.households(id),
  date         text not null,
  data         jsonb not null,
  created_at   timestamptz default now()
);
alter table public.nw_snapshots add column if not exists household_id uuid references public.households(id);
alter table public.nw_snapshots enable row level security;
drop policy if exists "users_own_snapshots" on public.nw_snapshots;
drop policy if exists "household_snapshots"  on public.nw_snapshots;
create policy "household_snapshots" on public.nw_snapshots
  for all using (
    household_id = public.get_my_household_id()
    or (household_id is null and user_id = auth.uid())
  ) with check (household_id = public.get_my_household_id());

-- ─── 5. Legacy per-user settings ─────────────────────────────────────────────

create table if not exists public.settings (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  tags       jsonb default '["Common","Travel","Adam","Zayn","Other"]'::jsonb,
  sub_cats   jsonb default '["Dining","Groceries","Transport","Insurance","Recreation","Shopping","Accommodation","Fuel","Pharmacy","Other"]'::jsonb,
  updated_at timestamptz default now()
);
alter table public.settings enable row level security;
drop policy if exists "users_own_settings" on public.settings;
create policy "users_own_settings" on public.settings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
