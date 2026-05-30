-- Run this entire file in your Supabase SQL Editor (supabase.com → project → SQL Editor)

-- Transactions
create table if not exists public.transactions (
  id          text        not null,
  user_id     uuid        not null references auth.users(id) on delete cascade,
  date        text,
  description text,
  amount      numeric(12,2),
  card        text,
  tag         text,
  sub         text,
  created_at  timestamptz default now(),
  primary key (id, user_id)
);
alter table public.transactions enable row level security;
create policy "users_own_transactions" on public.transactions
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Loaded files (CSV chip badges)
create table if not exists public.loaded_files (
  id         uuid  default gen_random_uuid() primary key,
  user_id    uuid  not null references auth.users(id) on delete cascade,
  name       text  not null,
  card_id    text,
  created_at timestamptz default now(),
  unique(user_id, name)
);
alter table public.loaded_files enable row level security;
create policy "users_own_files" on public.loaded_files
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Settings (custom tags / sub-categories)
create table if not exists public.settings (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  tags     jsonb default '["Common","Travel","Adam","Zayn","Other"]'::jsonb,
  sub_cats jsonb default '["Dining","Groceries","Transport","Insurance","Recreation","Shopping","Accommodation","Fuel","Pharmacy","Other"]'::jsonb,
  updated_at timestamptz default now()
);
alter table public.settings enable row level security;
create policy "users_own_settings" on public.settings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Billing Cycles (for expense tracker)
create table if not exists public.cycles (
  id         uuid default gen_random_uuid() primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null,
  created_at timestamptz default now()
);
alter table public.cycles enable row level security;
create policy "users_own_cycles" on public.cycles
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Add cycle_id to transactions (nullable for backward-compat migration)
alter table public.transactions add column if not exists cycle_id uuid references public.cycles(id) on delete cascade;

-- Add cycle_id to loaded_files; replace old unique(user_id, name) with (user_id, cycle_id, name)
alter table public.loaded_files add column if not exists cycle_id uuid references public.cycles(id) on delete cascade;
alter table public.loaded_files drop constraint if exists loaded_files_user_id_name_key;
alter table public.loaded_files add constraint if not exists loaded_files_user_id_cycle_id_name_key unique (user_id, cycle_id, name);

-- Net Worth Snapshots
create table if not exists public.nw_snapshots (
  id         uuid default gen_random_uuid() primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  date       text not null,
  data       jsonb not null,
  created_at timestamptz default now()
);
alter table public.nw_snapshots enable row level security;
create policy "users_own_snapshots" on public.nw_snapshots
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
