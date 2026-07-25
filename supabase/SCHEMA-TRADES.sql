-- HOODFACTORY — tabel trades untuk tracking volume swap (trending) & activity dashboard.
-- Jalankan di Supabase SQL Editor (atau sudah diterapkan otomatis oleh agent).

create table if not exists public.trades (
  id          bigint generated always as identity primary key,
  chain_id    integer      not null,
  token       text         not null,      -- token yang di-trade (lowercase)
  trader      text         not null,      -- wallet (lowercase)
  side        text         not null,      -- 'buy' | 'sell' | 'swap'
  eth_value   numeric      not null default 0, -- perkiraan volume dalam ETH
  tx_hash     text         not null,
  created_at  timestamptz  not null default now(),
  unique (chain_id, tx_hash, token)
);

create index if not exists trades_token_time_idx  on public.trades (chain_id, token, created_at desc);
create index if not exists trades_trader_time_idx on public.trades (chain_id, trader, created_at desc);

alter table public.trades enable row level security;

drop policy if exists "trades are publicly readable" on public.trades;
create policy "trades are publicly readable"
  on public.trades for select using (true);
-- Tulis hanya lewat service_role (endpoint /api/trades-register, setelah verifikasi tx on-chain).
