-- HOODFACTORY — rate limit agent gratis (per wallet) + langganan $10/bulan.
-- RLS aktif tanpa policy publik: hanya service_role (server) yang bisa baca/tulis,
-- jadi data pemakaian tidak bocor ke publik.

create table if not exists public.agent_chats (
  id          bigint generated always as identity primary key,
  chain_id    integer      not null default 4663,
  wallet      text         not null,     -- lowercase
  created_at  timestamptz  not null default now()
);
create index if not exists agent_chats_wallet_time_idx on public.agent_chats (wallet, created_at desc);

create table if not exists public.agent_subs (
  wallet      text         primary key,  -- lowercase
  expires_at  timestamptz  not null,
  tx_hash     text,
  updated_at  timestamptz  not null default now()
);
-- A confirmed payment transaction can activate exactly one subscription.
create unique index if not exists agent_subs_tx_hash_unique
  on public.agent_subs (tx_hash) where tx_hash is not null;

alter table public.agent_chats enable row level security;
alter table public.agent_subs  enable row level security;
-- Tidak ada policy select/insert utk anon: service_role bypass RLS (server-only).

-- Private, wallet-scoped conversation history. Reads require a wallet signature
-- through /api/agent-history; browser clients never receive Supabase credentials.
create table if not exists public.agent_conversations (
  id          text primary key,
  chain_id    integer      not null default 4663,
  wallet      text         not null,
  title       text         not null default 'New conversation',
  created_at  timestamptz  not null default now(),
  updated_at  timestamptz  not null default now()
);
create index if not exists agent_conversations_wallet_time_idx on public.agent_conversations (wallet, updated_at desc);

create table if not exists public.agent_messages (
  id              bigint generated always as identity primary key,
  conversation_id text         not null references public.agent_conversations(id) on delete cascade,
  chain_id        integer      not null default 4663,
  wallet          text         not null,
  turn_id         text         not null,
  role            text         not null check (role in ('user','assistant')),
  content         text         not null,
  message_type    text         not null default 'chat',
  created_at      timestamptz  not null default now(),
  unique(conversation_id, turn_id, role)
);
create index if not exists agent_messages_conversation_time_idx on public.agent_messages (conversation_id, created_at asc);
alter table public.agent_conversations enable row level security;
alter table public.agent_messages enable row level security;
