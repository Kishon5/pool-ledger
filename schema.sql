-- ============================================================
-- POOL LEDGER — complete Supabase schema, single file (v2.0)
-- Merge of DB1 (schema) + DB2 (recompute fix) + DB3 (patch v1.1),
-- keeping the newest version of every function.
-- Idempotent: safe to paste whole into the Supabase SQL editor and
-- run on a FRESH project or RE-RUN on an existing Pool Ledger DB.
--
-- All money is INTEGER CENTS (bigint). All times are timestamptz (UTC).
-- Balances are NEVER stored by hand — recompute_pool() derives everything
-- from the events table and writes results into derived tables.
-- Same-timestamp ordering rule: join/deposit/bonus BEFORE trade,
-- withdrawal/exit AFTER trade.
-- v2.3: withdrawal/exit events may carry fee_c — the broker's withdrawal
-- fee already contained in the gross amount_c. Display-only metadata:
-- the replay math is unchanged (balances move by the gross).
-- ============================================================

-- ---------- core tables ----------
create table if not exists admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists members (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  name text not null,
  email text,
  original_capital_c bigint not null check (original_capital_c >= 0),
  joined_at timestamptz not null,
  scrubbed boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists events (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('trade','deposit','withdrawal','exit','bonus')),
  order_time timestamptz not null,          -- real-world moment; drives ALL math
  created_at timestamptz not null default now(), -- entry moment; tie-breaker + audit only
  pnl_c bigint,                             -- trades only (may be negative)
  member_id uuid references members(id) on delete cascade,
  amount_c bigint,                          -- deposit/withdrawal/bonus
  fee_c bigint,                             -- withdrawal/exit: broker fee inside amount_c (display only)
  deleted boolean not null default false,   -- soft delete (Trash)
  created_by uuid default auth.uid()
);
-- upgrade path for databases created before v2.3 (create-if-not-exists above
-- won't touch an existing table)
alter table events add column if not exists fee_c bigint;
create index if not exists events_order_idx on events(order_time, created_at);

-- ---------- derived tables (written ONLY by recompute_pool) ----------
create table if not exists member_state (
  member_id uuid primary key references members(id) on delete cascade,
  balance_c bigint not null,
  contributed_c bigint not null,
  exited boolean not null,
  exited_at timestamptz,
  payout_c bigint,
  realized_c bigint,
  updated_at timestamptz not null default now()
);

-- per-trade split: one row per participating member, plus one NULL-member row
-- for the bonus sub-balance. Shares always sum exactly to the trade's P&L.
create table if not exists trade_allocations (
  id bigint generated always as identity primary key,
  event_id uuid not null references events(id) on delete cascade,
  member_id uuid references members(id) on delete cascade,
  order_time timestamptz not null,
  balance_before_c bigint not null,
  share_c bigint not null,
  balance_after_c bigint not null
);
create index if not exists trade_alloc_event_idx on trade_allocations(event_id);
create index if not exists trade_alloc_member_idx on trade_allocations(member_id, order_time);

create table if not exists member_history (
  id bigint generated always as identity primary key,
  member_id uuid not null references members(id) on delete cascade,
  t timestamptz not null,
  balance_c bigint not null
);
create index if not exists member_history_idx on member_history(member_id, t);

create table if not exists pool_history (
  id bigint generated always as identity primary key,
  t timestamptz not null,
  pool_c bigint not null,
  bonus_c bigint not null
);

create table if not exists pool_state (
  id int primary key default 1 check (id = 1),
  active_pool_c bigint not null,
  active_capital_c bigint not null,
  bonus_c bigint not null,
  event_count int not null,
  updated_at timestamptz not null default now()
);

create table if not exists replay_warnings (
  id bigint generated always as identity primary key,
  event_id uuid,
  msg text not null
);

create table if not exists audit_log (
  id bigint generated always as identity primary key,
  t timestamptz not null default now(),
  actor uuid,
  action text not null
);

-- ---------- helper: is the caller an admin? ----------
create or replace function me_is_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

-- first authenticated user can claim admin (only while admins is empty).
-- advisory lock closes the race where two users claim at the same instant.
create or replace function claim_admin() returns boolean
language plpgsql security definer set search_path = public as $$
begin
  perform pg_advisory_xact_lock(hashtext('pool_ledger_claim_admin'));
  if not exists (select 1 from admins) then
    insert into admins(user_id) values (auth.uid());
    insert into audit_log(actor, action) values (auth.uid(), 'Claimed first admin');
    return true;
  end if;
  return me_is_admin();
end $$;

-- promote another user to admin by email (must already exist in auth)
create or replace function make_admin(target_email text) returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not me_is_admin() then raise exception 'admins only'; end if;
  select id into uid from auth.users where lower(email) = lower(target_email) limit 1;
  if uid is null then return 'No user with that email — create them in Supabase Auth first.'; end if;
  insert into admins(user_id) values (uid) on conflict do nothing;
  insert into audit_log(actor, action) values (auth.uid(), 'Granted admin to ' || target_email);
  return 'ok';
end $$;

-- never remove the last admin
create or replace function guard_last_admin() returns trigger
language plpgsql set search_path = public as $$
begin
  if (select count(*) from admins) <= 1 then
    raise exception 'Cannot remove the last remaining admin.';
  end if;
  return old;
end $$;
drop trigger if exists trg_guard_last_admin on admins;
create trigger trg_guard_last_admin before delete on admins
for each row execute function guard_last_admin();

-- link a logged-in user to their member row by matching email (self-service)
create or replace function link_member() returns uuid
language plpgsql security definer set search_path = public as $$
declare mid uuid;
begin
  select id into mid from members where user_id = auth.uid() limit 1;
  if mid is not null then return mid; end if;
  update members set user_id = auth.uid()
   where id = (select id from members
               where user_id is null and lower(email) = lower(auth.email())
               order by created_at limit 1)
   returning id into mid;
  return mid;
end $$;

-- ============================================================
-- THE CANONICAL REPLAY ENGINE — the only place balances are computed
-- (DB2 version — the newest)
-- ============================================================
create or replace function recompute_pool() returns void
language plpgsql security definer set search_path = public as $$
declare
  ev record;
  v_bonus_c bigint := 0;
  v_member_total bigint;
  v_total bigint;
  v_bonus_share bigint;
  v_rem bigint;
  v_leftover bigint;
  v_name text;
begin
  drop table if exists st;
  create temp table st (
    member_id uuid primary key, bal_c bigint, contrib_c bigint,
    joined boolean, exited boolean, payout_c bigint, realized_c bigint, exited_at timestamptz
  ) on commit drop;
  insert into st select id, 0, 0, false, false, null, null, null from members;

  drop table if exists tmp_alloc;
  create temp table tmp_alloc (member_id uuid, bal_c bigint, share_c bigint, frac numeric) on commit drop;

  delete from trade_allocations where true;
  delete from member_history where true;
  delete from pool_history where true;
  delete from replay_warnings where true;

  for ev in
    select * from (
      -- join moments: capital enters exactly at joined_at
      select m.id as eid, '_join'::text as etype, m.joined_at as ot, m.created_at as ct,
             null::bigint as pnl, m.id as mid, m.original_capital_c as amt, 0 as prio
      from members m
      union all
      select e.id, e.type, e.order_time, e.created_at, e.pnl_c, e.member_id, e.amount_c,
             case e.type when 'deposit' then 1 when 'bonus' then 1
                         when 'trade' then 2
                         when 'withdrawal' then 3 when 'exit' then 4 end
      from events e where not e.deleted
    ) tl
    order by ot, prio, ct, eid
  loop
    if ev.etype = '_join' then
      update st set joined = true, bal_c = bal_c + ev.amt, contrib_c = contrib_c + ev.amt
        where member_id = ev.mid;

    elsif ev.etype = 'trade' then
      select coalesce(sum(bal_c),0) into v_member_total
        from st where joined and not exited and bal_c > 0;
      v_total := v_member_total + v_bonus_c;
      if v_total <= 0 then
        insert into replay_warnings(event_id, msg)
          values (ev.eid, 'Trade at ' || ev.ot || ' skipped — pool was $0 at that moment.');
        continue;
      end if;
      if v_total + ev.pnl < 0 then
        insert into replay_warnings(event_id, msg)
          values (ev.eid, 'Trade at ' || ev.ot || ' loses more than the pool held — balances went negative.');
      end if;
      -- 1) bonus sub-balance takes its proportional share FIRST (never divided among members)
      v_bonus_share := round((ev.pnl::numeric * v_bonus_c) / v_total)::bigint;
      v_rem := ev.pnl - v_bonus_share;
      -- 2) largest-remainder split of the remainder across participants by balance
      delete from tmp_alloc where true;
      insert into tmp_alloc
        select member_id, bal_c,
               trunc((v_rem::numeric * bal_c) / v_member_total)::bigint,
               abs(((v_rem::numeric * bal_c) / v_member_total)
                   - trunc((v_rem::numeric * bal_c) / v_member_total))
        from st where joined and not exited and bal_c > 0;
      v_leftover := v_rem - coalesce((select sum(share_c) from tmp_alloc), 0);
      if v_leftover <> 0 then
        update tmp_alloc a
           set share_c = share_c + (case when v_leftover > 0 then 1 else -1 end)
         where a.member_id in (
           select member_id from tmp_alloc
           order by frac desc, member_id limit abs(v_leftover));
      end if;
      -- record the per-member split for this trade (shares sum EXACTLY to pnl - bonus_share)
      insert into trade_allocations(event_id, member_id, order_time, balance_before_c, share_c, balance_after_c)
        select ev.eid, member_id, ev.ot, bal_c, share_c, bal_c + share_c from tmp_alloc;
      insert into trade_allocations(event_id, member_id, order_time, balance_before_c, share_c, balance_after_c)
        values (ev.eid, null, ev.ot, v_bonus_c, v_bonus_share, v_bonus_c + v_bonus_share);
      v_bonus_c := v_bonus_c + v_bonus_share;
      update st s set bal_c = s.bal_c + a.share_c
        from tmp_alloc a where a.member_id = s.member_id;

    elsif ev.etype = 'deposit' then
      select name into v_name from members where id = ev.mid;
      if exists (select 1 from st where member_id = ev.mid and exited) then
        insert into replay_warnings(event_id,msg) values (ev.eid, 'Deposit for '||v_name||' dated after their exit.');
      end if;
      if exists (select 1 from st where member_id = ev.mid and not joined) then
        insert into replay_warnings(event_id,msg) values (ev.eid, 'Deposit for '||v_name||' dated before their join date.');
      end if;
      update st set bal_c = bal_c + ev.amt, contrib_c = contrib_c + ev.amt where member_id = ev.mid;

    elsif ev.etype = 'withdrawal' then
      select name into v_name from members where id = ev.mid;
      if exists (select 1 from st where member_id = ev.mid
                 and ev.amt > greatest(0, bal_c - contrib_c)) then
        insert into replay_warnings(event_id,msg) values (ev.eid,
          'Withdrawal for '||v_name||' exceeds their profit at that point in history — likely a later backdated edit.');
      end if;
      update st set bal_c = bal_c - ev.amt where member_id = ev.mid;

    elsif ev.etype = 'exit' then
      update st set payout_c = bal_c, realized_c = bal_c - contrib_c,
                    bal_c = 0, exited = true, exited_at = ev.ot
        where member_id = ev.mid;

    elsif ev.etype = 'bonus' then
      v_bonus_c := v_bonus_c + ev.amt;
      if v_bonus_c < 0 then
        insert into replay_warnings(event_id,msg) values (ev.eid, 'Bonus balance went negative at '||ev.ot||'.');
      end if;
    end if;

    if ev.etype <> '_join' then
      insert into pool_history(t, pool_c, bonus_c)
        select ev.ot, coalesce(sum(case when exited then 0 else bal_c end),0), v_bonus_c from st;
    end if;
    insert into member_history(member_id, t, balance_c)
      select member_id, ev.ot, bal_c from st where joined;
  end loop;

  -- final derived state
  insert into member_state(member_id, balance_c, contributed_c, exited, exited_at, payout_c, realized_c, updated_at)
    select member_id, bal_c, contrib_c, exited, exited_at, payout_c, realized_c, now() from st
  on conflict (member_id) do update
    set balance_c = excluded.balance_c, contributed_c = excluded.contributed_c,
        exited = excluded.exited, exited_at = excluded.exited_at,
        payout_c = excluded.payout_c, realized_c = excluded.realized_c, updated_at = now();
  delete from member_state where member_id not in (select id from members);

  insert into pool_state(id, active_pool_c, active_capital_c, bonus_c, event_count, updated_at)
    select 1,
      coalesce((select sum(bal_c) from st where not exited),0),
      coalesce((select sum(contrib_c) from st where not exited),0),
      v_bonus_c,
      (select count(*) from events where not deleted),
      now()
  on conflict (id) do update
    set active_pool_c = excluded.active_pool_c, active_capital_c = excluded.active_capital_c,
        bonus_c = excluded.bonus_c, event_count = excluded.event_count, updated_at = now();
end $$;

-- ---------- validation BEFORE anything is written ----------
-- (DB3 version: skips checks while a restore is running — a legitimate
--  backup may contain events that today's state would reject)
create or replace function validate_event() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_avail bigint; v_pool bigint; v_exited boolean;
begin
  if current_setting('app.restore', true) = 'on' then return new; end if;
  if new.type = 'trade' then
    if new.pnl_c is null or new.pnl_c = 0 then raise exception 'Trade needs a non-zero P&L.'; end if;
    select coalesce(active_pool_c,0) + coalesce(bonus_c,0) into v_pool from pool_state;
    if coalesce(v_pool, (select coalesce(sum(original_capital_c),0) from members)) <= 0 then
      raise exception 'Pool is at $0 — new trades are blocked until fresh capital is deposited.';
    end if;
  elsif new.type in ('deposit','withdrawal','exit') then
    if new.member_id is null then raise exception 'member_id required'; end if;
    select exited into v_exited from member_state where member_id = new.member_id;
    if coalesce(v_exited,false) then raise exception 'Member already exited.'; end if;
    if new.type = 'withdrawal' then
      select greatest(0, balance_c - contributed_c) into v_avail
        from member_state where member_id = new.member_id;
      if new.amount_c > coalesce(v_avail,0) then
        raise exception 'Withdrawals are profit-only. Available profit: % cents. Use Exit to return capital.', coalesce(v_avail,0);
      end if;
    end if;
    if new.type in ('deposit','withdrawal') and (new.amount_c is null or new.amount_c <= 0) then
      raise exception 'Amount must be positive.';
    end if;
    -- broker fee is part of amount_c (gross); the member received amount_c - fee_c
    if new.fee_c is not null and new.fee_c < 0 then
      raise exception 'Broker fee cannot be negative.';
    end if;
    if new.type = 'withdrawal' and new.fee_c is not null and new.fee_c >= new.amount_c then
      raise exception 'Broker fee must be smaller than the withdrawal amount.';
    end if;
  elsif new.type = 'bonus' then
    if new.amount_c is null or new.amount_c = 0 then raise exception 'Bonus amount required.'; end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_validate_event on events;
create trigger trg_validate_event before insert on events
for each row execute function validate_event();

-- block deleting a member who has any financial history (use Exit / purge_member instead)
create or replace function guard_member_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_setting('app.purge', true) = 'on' then return old; end if;
  if exists (select 1 from events where member_id = old.id)
     or exists (select 1 from trade_allocations where member_id = old.id) then
    raise exception 'This member has financial history and cannot be deleted. Use Exit instead — it pays out their balance and archives them with their full history preserved.';
  end if;
  return old;
end $$;
drop trigger if exists trg_guard_member_delete on members;
create trigger trg_guard_member_delete before delete on members
for each row execute function guard_member_delete();

-- permanent delete from Archive (heavily-warned path; recalculates history)
-- (DB3 version: records the member's name instead of a raw UUID)
create or replace function purge_member(target uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if not me_is_admin() then raise exception 'admins only'; end if;
  select name into v_name from members where id = target;
  perform set_config('app.purge','on', true);
  delete from events where member_id = target;
  delete from members where id = target;
  insert into audit_log(actor, action)
    values (auth.uid(), 'PERMANENTLY deleted archived member "' || coalesce(v_name,'(unknown)') || '"');
end $$;

-- ---------- audit (append-only) + recompute triggers ----------
-- (DB3 version: restores are logged as one summary entry, not per row)
create or replace function audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare d text;
begin
  if current_setting('app.restore', true) = 'on' then return coalesce(new, old); end if;
  if tg_table_name = 'events' then
    if tg_op = 'UPDATE' and old.deleted is distinct from new.deleted then
      d := (case when new.deleted then 'Trashed ' else 'Restored ' end) || new.type || ' @ ' || new.order_time;
    else
      d := tg_op || ' ' || coalesce(new.type, old.type) || ' @ ' || coalesce(new.order_time, old.order_time);
    end if;
  else
    d := tg_op || ' member ' || coalesce(new.name, old.name);
  end if;
  insert into audit_log(actor, action) values (auth.uid(), d);
  return coalesce(new, old);
end $$;
drop trigger if exists trg_audit_events on events;
create trigger trg_audit_events after insert or update or delete on events
for each row execute function audit_row();
drop trigger if exists trg_audit_members on members;
create trigger trg_audit_members after insert or update or delete on members
for each row execute function audit_row();

create or replace function trg_recompute() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform recompute_pool(); return null; end $$;
drop trigger if exists trg_recompute_events on events;
create trigger trg_recompute_events after insert or update or delete on events
for each statement execute function trg_recompute();
drop trigger if exists trg_recompute_members on members;
create trigger trg_recompute_members after insert or update or delete on members
for each statement execute function trg_recompute();

-- ============================================================
-- RESTORE FROM BACKUP (replace mode)
-- Wipes members + events, re-inserts from the JSON payload, and lets the
-- normal recompute trigger rebuild every balance/split from scratch.
-- Old audit entries from the file are imported only if the current audit
-- log is empty (i.e. restoring into a fresh project).
-- Note: member↔login links (user_id) are intentionally NOT restored; members
-- re-link automatically by email on their next sign-in.
-- ============================================================
create or replace function restore_backup(payload jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare n_members int; n_events int;
begin
  if not me_is_admin() then raise exception 'admins only'; end if;
  if payload->'members' is null or payload->'events' is null then
    raise exception 'Backup file is missing members or events.';
  end if;

  perform set_config('app.purge','on', true);
  perform set_config('app.restore','on', true);

  delete from events where true;
  delete from members where true;

  insert into members (id, name, email, original_capital_c, joined_at, scrubbed, created_at)
  select (m->>'id')::uuid,
         m->>'name',
         nullif(m->>'email',''),
         (m->>'original_capital_c')::bigint,
         (m->>'joined_at')::timestamptz,
         coalesce((m->>'scrubbed')::boolean, false),
         coalesce((m->>'created_at')::timestamptz, now())
  from jsonb_array_elements(payload->'members') m;

  insert into events (id, type, order_time, created_at, pnl_c, member_id, amount_c, fee_c, deleted)
  select (e->>'id')::uuid,
         e->>'type',
         (e->>'order_time')::timestamptz,
         coalesce((e->>'created_at')::timestamptz, now()),
         (e->>'pnl_c')::bigint,
         (e->>'member_id')::uuid,
         (e->>'amount_c')::bigint,
         (e->>'fee_c')::bigint,          -- absent in pre-v2.3 backups -> null
         coalesce((e->>'deleted')::boolean, false)
  from jsonb_array_elements(payload->'events') e;

  if not exists (select 1 from audit_log) and payload->'audit_log' is not null then
    insert into audit_log (t, actor, action)
    select coalesce((a->>'t')::timestamptz, now()),
           (a->>'actor')::uuid,
           '[imported] ' || (a->>'action')
    from jsonb_array_elements(payload->'audit_log') a;
  end if;

  perform set_config('app.restore','off', true);
  perform recompute_pool();

  select count(*) into n_members from members;
  select count(*) into n_events from events;
  insert into audit_log(actor, action)
    values (auth.uid(), 'RESTORED backup: ' || n_members || ' members, ' || n_events || ' events (all balances recomputed)');
  return 'Restored ' || n_members || ' members and ' || n_events || ' events.';
end $$;

-- ============================================================
-- ROW-LEVEL SECURITY — members can never see the pool or each other
-- (drop-then-create so this file can be re-run safely)
-- ============================================================
alter table admins            enable row level security;
alter table members           enable row level security;
alter table events            enable row level security;
alter table member_state      enable row level security;
alter table trade_allocations enable row level security;
alter table member_history    enable row level security;
alter table pool_history      enable row level security;
alter table pool_state        enable row level security;
alter table replay_warnings   enable row level security;
alter table audit_log         enable row level security;

drop policy if exists admins_admin on admins;
create policy admins_admin on admins for all using (me_is_admin()) with check (me_is_admin());

drop policy if exists members_admin on members;
create policy members_admin on members for all using (me_is_admin()) with check (me_is_admin());
drop policy if exists members_self on members;
create policy members_self  on members for select using (user_id = auth.uid());

drop policy if exists events_admin on events;
create policy events_admin on events for all using (me_is_admin()) with check (me_is_admin());
-- members may see ONLY their own deposits/withdrawals/exits — never trades or others'
drop policy if exists events_self on events;
create policy events_self on events for select
  using (member_id in (select id from members where user_id = auth.uid()));

drop policy if exists mstate_admin on member_state;
create policy mstate_admin on member_state for all using (me_is_admin()) with check (me_is_admin());
drop policy if exists mstate_self on member_state;
create policy mstate_self  on member_state for select
  using (member_id in (select id from members where user_id = auth.uid()));

drop policy if exists alloc_admin on trade_allocations;
create policy alloc_admin on trade_allocations for all using (me_is_admin()) with check (me_is_admin());
drop policy if exists alloc_self on trade_allocations;
create policy alloc_self  on trade_allocations for select
  using (member_id in (select id from members where user_id = auth.uid()));

drop policy if exists mhist_admin on member_history;
create policy mhist_admin on member_history for all using (me_is_admin()) with check (me_is_admin());
drop policy if exists mhist_self on member_history;
create policy mhist_self  on member_history for select
  using (member_id in (select id from members where user_id = auth.uid()));

drop policy if exists phist_admin on pool_history;
create policy phist_admin on pool_history for all using (me_is_admin()) with check (me_is_admin());
drop policy if exists pstate_admin on pool_state;
create policy pstate_admin on pool_state  for all using (me_is_admin()) with check (me_is_admin());
drop policy if exists warn_admin on replay_warnings;
create policy warn_admin  on replay_warnings for all using (me_is_admin()) with check (me_is_admin());

-- audit log: admins may READ; nobody may update or delete (no policies exist for those)
drop policy if exists audit_read on audit_log;
create policy audit_read on audit_log for select using (me_is_admin());

-- ============================================================
-- HARDENING — every function above is SECURITY DEFINER and PostgREST
-- auto-exposes each at /rest/v1/rpc/<name> with EXECUTE granted to
-- anon+authenticated by default. We tighten that by category:
--
--  * Trigger bodies + the heavy replay are never meant to be RPC-callable
--    at all — revoke from everyone. (Triggers still fire: they run as the
--    table owner, not as the API caller, so table DML is unaffected.)
--    This closes the hole where trg_recompute() — the trigger wrapper —
--    could invoke the otherwise-locked recompute_pool() via RPC.
--
--  * Admin actions are called by the admin, who is just an 'authenticated'
--    user distinguished by the admins table (not a DB role). They must stay
--    EXECUTE-able by authenticated and are gated by an internal me_is_admin()
--    check; we deny anon.
--
--  * Sign-in helpers (claim_admin, link_member) are only ever called with a
--    live session — deny anon.
--
--  * me_is_admin() is DELIBERATELY left callable by anon+authenticated: it is
--    referenced by every RLS policy below and is evaluated as the querying
--    role, so revoking it would break all member/admin queries. Calling it
--    directly only tells you whether YOU are an admin — no data leak.
-- ============================================================
-- trigger bodies + heavy replay: no API caller should reach these
revoke execute on function recompute_pool()      from public, anon, authenticated;
revoke execute on function trg_recompute()       from public, anon, authenticated;
revoke execute on function audit_row()           from public, anon, authenticated;
revoke execute on function validate_event()      from public, anon, authenticated;
revoke execute on function guard_member_delete() from public, anon, authenticated;
revoke execute on function guard_last_admin()    from public, anon, authenticated;
-- admin actions + sign-in helpers: revoke the default PUBLIC grant (which is
-- what anon inherits — revoking the anon role alone leaves PUBLIC in place and
-- does nothing), then grant back to authenticated only. Admin actions stay
-- gated by their internal me_is_admin() check.
revoke execute on function make_admin(text)      from public;
revoke execute on function restore_backup(jsonb) from public;
revoke execute on function purge_member(uuid)    from public;
revoke execute on function claim_admin()         from public;
revoke execute on function link_member()         from public;
grant  execute on function make_admin(text)      to authenticated;
grant  execute on function restore_backup(jsonb) to authenticated;
grant  execute on function purge_member(uuid)    to authenticated;
grant  execute on function claim_admin()         to authenticated;
grant  execute on function link_member()         to authenticated;

-- ============================================================
-- REALTIME — open devices refresh instantly when data changes.
-- Included in the Supabase free tier (200 concurrent connections,
-- 2M messages/month). postgres_changes respects RLS: the admin hears
-- events/members; each member hears only their own member_state row.
-- Wrapped so re-running this file never errors.
-- ============================================================
do $$ begin alter publication supabase_realtime add table events;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table members;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table member_state;
exception when duplicate_object then null; end $$;
