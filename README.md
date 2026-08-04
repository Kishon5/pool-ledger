# Pool Ledger

A single-file web app for tracking a shared trading pool — members, deposits, withdrawals, per-trade profit splits, and a full audit trail. Backed by [Supabase](https://supabase.com) (Postgres + Auth + Realtime); all balances are derived by replaying the event ledger, never stored by hand.

## Features

- **Admin dashboard** — pool KPIs, ownership breakdown, trade logging with an exact split preview, event history with filters, trash/restore, archive, append-only audit log
- **Screenshot import** — photograph/screenshot your broker's order list and the app OCRs it on-device (Tesseract.js, image never uploaded), extracts each trade's P&L and settlement time, flags likely duplicates, and lets you review every value before saving
- **Broker withdrawal fees** — type what the member should receive in hand and a live preview shows the gross to withdraw from the broker, the fee (max of a % of gross and a flat minimum — defaults 25% / $50), and the extra funds needed; the fee is recorded on the event and shown in history, statements, and CSV exports
- **Bonus funds** — the admin's own money in the pool, held as a single sub-balance rather than as a member. It takes its proportional cut of every trade *before* members split the rest, and compounds. Top it up or withdraw it (same in-hand fee flow as a member withdrawal) with a live preview of the balance at that point in history; it can never be drawn below zero, at its own moment or at any later one. Admin-only — row-level security keeps it invisible to members.
- **Admin-managed passwords** — no self-service reset; the admin sets member passwords in Supabase Auth
- **Member portal** — each member sees only their own balance, history, charts, and statements (enforced by Postgres row-level security)
- **Money-exact math** — integer cents everywhere; largest-remainder allocation mirrors the Postgres replay engine to the cent
- **Monthly statements** (printable), CSV export, JSON backup/restore
- **Realtime sync** across open devices, dark/light themes, 4 color palettes

## Trading Growth Calculator (`calculator.html`)

A separate, standalone tool in this repo — a compound-growth calculator for trading. It is **only arithmetic**: no exchange, broker, wallet or trading-platform connection, no network requests of any kind.

Open `calculator.html` in any browser, or "Add to Home Screen" on Android/iPhone to run it as an offline app. It shares nothing with the pool ledger — no Supabase, no accounts, no setup.

`calculator.html` is self-contained and runs on its own from anywhere, including a `file://` path. Two extra files exist only so the installed app gets its own identity and icon: `calculator.webmanifest` and `calculator-assets/`. Keep the three together when hosting; without them the page still works, it just installs as a generic bookmark. `start_url` in the manifest is `calculator.html` — a relative `"."` there resolves to the directory, which on a site whose root is `index.html` launches the pool ledger instead.

- **Per-trade compounding** — the balance grows by the profit % after *every* trade and is rounded to cents each time, so the next trade compounds the rounded balance and every displayed row adds up exactly. Compounding can be switched off for flat profit per trade.
- **Results** — final balance, total profit, ROI, total trades; then, if a fee % is set, what you withdraw, the fee, what reaches your hand, what stays in the account, and net worth after the fee
- **Fees are charged on whatever you withdraw**, not on profit as a category, with an optional flat minimum that applies when the percentage falls short of it. Choose whether you take out the profit and leave your capital trading, take out everything, or take out nothing — the fee follows.
- **Withdrawal planner** — enter the amount you need *in your hand* and it solves backwards through the fee to the balance you must reach, then reports the trades and days and builds the growth table for exactly that run, stopping mid-day on the trade that gets you there
- **Target calculator** — trades needed, days needed and the calendar date you hit a goal, with a second set of figures for keeping the target *after* the fee
- **Growth table** — daily view, or trade-by-trade with each day separated by a banded header showing the weekday and date, plus a per-day total row
- **PDF export** — settings, results and the full table, written by a built-in PDF generator (no library, so it works offline); filenames like `Growth_1000USD_60Days_4Trades.pdf` or `Withdraw_2000USD_39Days_154Trades.pdf`
- **Compare** — up to six starting capitals under identical settings, as a summary or as a day-by-day / trade-by-trade grid with one column per capital, exportable to PDF and CSV
- **Also** — CSV export, copy result as text, share as an image, save calculations to device history, 23 currencies, presets, dark mode

Days are calendar days including weekends, and Day 1 is the start date you choose. Risk per trade % is informational — it shows risk amount, reward:risk, break-even win rate and losses-to-halve-capital, and does not affect the projection.

## Setup

1. Create a free [Supabase](https://supabase.com) project
2. Paste the entire `schema.sql` into the Supabase SQL editor and run it
3. Put your project URL and anon key into the `CONFIG` block at the top of `index.html`
4. Host `index.html` anywhere static (GitHub Pages works) — or just open it locally
5. Create your admin login in Supabase Auth → sign in; the first user to sign in becomes admin

The Supabase anon key in the file is public by design — every read/write is gated by row-level security policies defined in `schema.sql`.

## Security setup (do this before going live)

The anon key ships in the public HTML, so **all** security rests on Postgres RLS
plus your Supabase Auth settings. `schema.sql` already locks down RLS and function
grants; these three Auth settings are yours to set in the dashboard:

1. **Turn off open signups** — Authentication → Providers → Email → disable
   "Allow new users to sign up". Because the *first* person to sign in becomes the
   admin (`claim_admin`), an open signup lets a stranger who loads the page before
   you seize admin. With signups off, you create every login yourself
   (Authentication → Users → Add user), which matches the admin-managed-password
   model anyway. Do this **before** you first open the app.
2. **Require email confirmation** — Authentication → Providers → Email → enable
   "Confirm email". Members are linked to their data by matching email
   (`link_member`); without confirmation, someone could register a member's email
   they don't own and read that member's balance and history.
3. **Enable leaked-password protection** — Authentication → Passwords → turn on the
   HaveIBeenPwned check so breached passwords are rejected.

Run `schema.sql` in full (it is idempotent) after any pull — the hardening lives in
its `HARDENING` block and re-applies cleanly.

## Architecture

- **`index.html`** — the whole app: vanilla JS + CSS, no build step
- **`schema.sql`** — complete idempotent database schema: tables, replay engine (`recompute_pool`), validation triggers, RLS policies, realtime publication
- **`calculator.html`** — the standalone growth calculator; independent of everything above, offline, zero dependencies
- **`calculator.webmanifest`** + **`calculator-assets/`** — install metadata and PNG icons for the calculator's home-screen app

All money is integer cents (`bigint`). All timestamps are UTC (`timestamptz`), displayed in the viewer's local time. Same-timestamp ordering rule: join/deposit/bonus **before** trade, withdrawal/exit **after** trade.
