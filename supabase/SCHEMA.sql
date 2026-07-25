-- HOODFACTORY — schema Supabase untuk marketplace token.
-- Jalankan sekali di Supabase Dashboard > SQL Editor > New query > Run.

create table if not exists public.tokens (
  id            bigint generated always as identity primary key,
  chain_id      integer      not null,
  address       text         not null,          -- alamat kontrak token (lowercase)
  name          text         not null,
  symbol        text         not null,
  creator       text         not null,          -- wallet pembuat (lowercase)
  pool          text         not null,          -- alamat pool Uniswap V3
  tx_hash       text         not null,          -- tx createCoin
  created_at    timestamptz  not null default now(),
  unique (chain_id, address)
);

create index if not exists tokens_chain_created_idx
  on public.tokens (chain_id, created_at desc);

alter table public.tokens add column if not exists description text;
alter table public.tokens add column if not exists image_url text;
alter table public.tokens add column if not exists website_url text;
alter table public.tokens add column if not exists x_url text;
alter table public.tokens add column if not exists telegram_url text;
alter table public.tokens add column if not exists metadata_locked boolean not null default false;
alter table public.tokens add column if not exists metadata_updated_at timestamptz;

-- Stock pair: token yang di-launch lewat HoodStockLaunchpad dipasangkan ke
-- Stock Token Robinhood, bukan WETH. NULL = pool Token/WETH (jalur lama).
alter table public.tokens add column if not exists pair_token text;
alter table public.tokens add column if not exists pair_symbol text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('token-media','token-media',true,262144,array['image/png','image/jpeg','image/webp'])
on conflict (id) do update set public=true, file_size_limit=262144,
  allowed_mime_types=array['image/png','image/jpeg','image/webp'];

-- RLS: publik boleh BACA, tapi tulis hanya lewat service_role key
-- (dipakai serverless /api/tokens-register setelah verifikasi on-chain).
alter table public.tokens enable row level security;

drop policy if exists "tokens are publicly readable" on public.tokens;
create policy "tokens are publicly readable"
  on public.tokens for select
  using (true);

-- Tidak ada policy insert/update/delete untuk anon/authenticated:
-- service_role melewati RLS, jadi hanya server yang bisa menulis.
