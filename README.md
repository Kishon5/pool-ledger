# Pool Ledger

A single-file web app for tracking a shared trading pool — members, deposits, withdrawals, per-trade profit splits, and a full audit trail. Backed by [Supabase](https://supabase.com) (Postgres + Auth + Realtime); all balances are derived by replaying the event ledger, never stored by hand.

## Features

- **Admin dashboard** — pool KPIs, ownership breakdown, trade logging with an exact split preview, event history with filters, trash/restore, archive, append-only audit log
- **Screenshot import** — photograph/screenshot your broker's order list and the app OCRs it on-device (Tesseract.js, image never uploaded), extracts each trade's P&L and settlement time, flags likely duplicates, and lets you review every value before saving
- **Broker withdrawal fees** — type what the member should receive in hand and a live preview shows the gross to withdraw from the broker, the fee (max of a % of gross and a flat minimum — defaults 25% / $50), and the extra funds needed; the fee is recorded on the event and shown in history, statements, and CSV exports
- **Admin-managed passwords** — no self-service reset; the admin sets member passwords in Supabase Auth
- **Member portal** — each member sees only their own balance, history, charts, and statements (enforced by Postgres row-level security)
- **Money-exact math** — integer cents everywhere; largest-remainder allocation mirrors the Postgres replay engine to the cent
- **Monthly statements** (printable), CSV export, JSON backup/restore
- **Realtime sync** across open devices, dark/light themes, 4 color palettes

## Setup

1. Create a free [Supabase](https://supabase.com) project
2. Paste the entire `schema.sql` into the Supabase SQL editor and run it
3. Put your project URL and anon key into the `CONFIG` block at the top of `index.html`
4. Host `index.html` anywhere static (GitHub Pages works) — or just open it locally
5. Create your admin login in Supabase Auth → sign in; the first user to sign in becomes admin

The Supabase anon key in the file is public by design — every read/write is gated by row-level security policies defined in `schema.sql`.

## Architecture

- **`index.html`** — the whole app: vanilla JS + CSS, no build step
- **`schema.sql`** — complete idempotent database schema: tables, replay engine (`recompute_pool`), validation triggers, RLS policies, realtime publication

All money is integer cents (`bigint`). All timestamps are UTC (`timestamptz`), displayed in the viewer's local time. Same-timestamp ordering rule: join/deposit/bonus **before** trade, withdrawal/exit **after** trade.
