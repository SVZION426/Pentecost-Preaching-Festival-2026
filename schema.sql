-- ============================================================
-- Preaching & Bible Study Point Tracker
-- Supabase / Postgres schema, policies and RPC layer
-- Run this whole file once in the Supabase SQL editor.
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------

create table if not exists members (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  group_name  text not null check (group_name in ('evangelist','member')),
  pin_hash    text not null,
  is_admin    boolean not null default false,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists goals (
  id             uuid primary key default gen_random_uuid(),
  group_name     text not null check (group_name in ('evangelist','member')),
  category       text not null check (category in ('preaching','valid','baptism','attendance')),
  target         integer not null check (target >= 0),
  effective_from date not null default '2000-01-01'
);

create table if not exists point_values (
  id             uuid primary key default gen_random_uuid(),
  category       text not null check (category in ('preaching','valid','baptism','attendance')),
  points         integer not null check (points >= 0),
  effective_from date not null default '2000-01-01'
);

create table if not exists preaching_entries (
  id         uuid primary key default gen_random_uuid(),
  member_id  uuid not null references members(id) on delete cascade,
  entry_date date not null default current_date,
  count      integer not null check (count > 0),
  note       text,
  created_at timestamptz not null default now()
);

-- The only table holding names of people outside the team.
-- Locked down completely; reachable only through the RPCs below.
create table if not exists contacts (
  id         uuid primary key default gen_random_uuid(),
  member_id  uuid not null references members(id) on delete cascade,
  name       text not null,
  note       text,
  created_at timestamptz not null default now()
);

create table if not exists contact_events (
  id         uuid primary key default gen_random_uuid(),
  contact_id uuid not null references contacts(id) on delete cascade,
  member_id  uuid not null references members(id) on delete cascade,
  event_type text not null check (event_type in ('valid','baptism','attendance')),
  event_date date not null default current_date,
  note       text,
  created_at timestamptz not null default now()
);

create index if not exists idx_pe_member_date on preaching_entries (member_id, entry_date);
create index if not exists idx_ce_member_date on contact_events (member_id, event_date);
create index if not exists idx_ce_contact     on contact_events (contact_id, event_type);
create index if not exists idx_contacts_member on contacts (member_id);

-- ------------------------------------------------------------
-- Seed: goals and point values
-- effective_from versioning means changing a target never
-- rewrites the points or progress of a month already closed.
-- ------------------------------------------------------------

insert into goals (group_name, category, target)
select * from (values
  ('evangelist','preaching',300), ('evangelist','valid',10),
  ('evangelist','baptism',1),     ('evangelist','attendance',1),
  ('member','preaching',200),     ('member','valid',5),
  ('member','baptism',1),         ('member','attendance',0)
) v(g,c,t)
where not exists (select 1 from goals);

insert into point_values (category, points)
select * from (values
  ('preaching',1), ('valid',50), ('baptism',500), ('attendance',1000)
) v(c,p)
where not exists (select 1 from point_values);

-- ------------------------------------------------------------
-- Effective-value helpers
-- ------------------------------------------------------------

create or replace function point_value_at(p_category text, p_date date)
returns integer language sql stable as $$
  select points from point_values
   where category = p_category and effective_from <= p_date
   order by effective_from desc limit 1;
$$;

create or replace function goal_target_at(p_group text, p_category text, p_date date)
returns integer language sql stable as $$
  select target from goals
   where group_name = p_group and category = p_category and effective_from <= p_date
   order by effective_from desc limit 1;
$$;

-- ------------------------------------------------------------
-- Scoring
--
-- Rule 1  Highest stage only: within a month a contact scores
--         once, at the value of the best stage they reached.
-- Rule 2  Attendance scores once per contact per month.
--
-- Both rules fall out of a single MAX over the month's events,
-- because the point ladder rises with the funnel.
-- ------------------------------------------------------------

create or replace view v_monthly_contact_points as
  select ce.member_id,
         date_trunc('month', ce.event_date)::date as month,
         ce.contact_id,
         max(point_value_at(ce.event_type, ce.event_date)) as points
    from contact_events ce
   group by 1, 2, 3;

-- Team-visible aggregate. Carries counts and points only.
-- No contact names ever pass through this view.
create or replace view v_monthly_stats as
  with months as (
    select member_id, date_trunc('month', entry_date)::date as month from preaching_entries
    union
    select member_id, date_trunc('month', event_date)::date as month from contact_events
  ),
  pr as (
    select member_id, date_trunc('month', entry_date)::date as month,
           sum(count)::int as preaching_count,
           sum(count * point_value_at('preaching', entry_date))::int as preaching_points
      from preaching_entries group by 1, 2
  ),
  ct as (
    select member_id, date_trunc('month', event_date)::date as month,
           count(distinct contact_id) filter (where event_type = 'valid')::int      as valid_count,
           count(distinct contact_id) filter (where event_type = 'baptism')::int    as baptism_count,
           count(distinct contact_id) filter (where event_type = 'attendance')::int as attendance_count
      from contact_events group by 1, 2
  ),
  cp as (
    select member_id, month, sum(points)::int as contact_points
      from v_monthly_contact_points group by 1, 2
  )
  select mo.member_id,
         m.name,
         m.group_name,
         m.is_active,
         mo.month,
         coalesce(pr.preaching_count, 0)   as preaching_count,
         coalesce(ct.valid_count, 0)       as valid_count,
         coalesce(ct.baptism_count, 0)     as baptism_count,
         coalesce(ct.attendance_count, 0)  as attendance_count,
         coalesce(pr.preaching_points, 0) + coalesce(cp.contact_points, 0) as points,
         goal_target_at(m.group_name, 'preaching',  mo.month) as goal_preaching,
         goal_target_at(m.group_name, 'valid',      mo.month) as goal_valid,
         goal_target_at(m.group_name, 'baptism',    mo.month) as goal_baptism,
         goal_target_at(m.group_name, 'attendance', mo.month) as goal_attendance
    from months mo
    join members m on m.id = mo.member_id
    left join pr on pr.member_id = mo.member_id and pr.month = mo.month
    left join ct on ct.member_id = mo.member_id and ct.month = mo.month
    left join cp on cp.member_id = mo.member_id and cp.month = mo.month;

-- Funnel: where each member's people currently sit.
-- Stage is derived from events, so nothing can be "retained"
-- without a baptism behind it.
create or replace view v_funnel as
  select c.member_id,
         m.group_name,
         c.id as contact_id,
         case
           when exists (select 1 from contact_events e where e.contact_id = c.id and e.event_type = 'attendance') then 'retained'
           when exists (select 1 from contact_events e where e.contact_id = c.id and e.event_type = 'baptism')    then 'baptized'
           else 'valid'
         end as stage,
         (select max(event_date) from contact_events e
           where e.contact_id = c.id and e.event_type = 'attendance') as last_attended
    from contacts c
    join members m on m.id = c.member_id;

-- Team-visible roster without PIN hashes.
create or replace view v_members_public as
  select id, name, group_name, is_admin, is_active, created_at from members;

-- ------------------------------------------------------------
-- Row level security
--
-- contacts    : no policy at all. Unreachable from the browser.
-- everything  : readable (it carries IDs and numbers, no names),
-- else          so Realtime can push changes to the team board.
-- Writes on every table go through the SECURITY DEFINER
-- functions below, which verify a PIN first.
-- ------------------------------------------------------------

alter table members           enable row level security;
alter table goals             enable row level security;
alter table point_values      enable row level security;
alter table preaching_entries enable row level security;
alter table contacts          enable row level security;
alter table contact_events    enable row level security;

revoke select on members from anon, authenticated;
grant  select on v_members_public, v_monthly_stats, v_funnel to anon, authenticated;

drop policy if exists read_goals  on goals;
drop policy if exists read_points on point_values;
drop policy if exists read_pe     on preaching_entries;
drop policy if exists read_ce     on contact_events;

create policy read_goals  on goals             for select using (true);
create policy read_points on point_values      for select using (true);
create policy read_pe     on preaching_entries for select using (true);
create policy read_ce     on contact_events    for select using (true);

-- ------------------------------------------------------------
-- Internal auth helper. Not callable from the browser.
-- ------------------------------------------------------------

create or replace function _auth(p_member_id uuid, p_pin text, p_require_admin boolean default false)
returns members language plpgsql stable security definer as $$
declare m members;
begin
  select * into m from members
   where id = p_member_id and is_active and pin_hash = crypt(p_pin, pin_hash);
  if m.id is null then
    raise exception 'Wrong PIN' using errcode = '28000';
  end if;
  if p_require_admin and not m.is_admin then
    raise exception 'Admin PIN required' using errcode = '42501';
  end if;
  return m;
end $$;

revoke execute on function _auth(uuid, text, boolean) from anon, authenticated, public;

-- ------------------------------------------------------------
-- Participant RPCs
-- ------------------------------------------------------------

create or replace function login(p_member_id uuid, p_pin text)
returns jsonb language plpgsql stable security definer as $$
declare m members;
begin
  m := _auth(p_member_id, p_pin);
  return jsonb_build_object('id', m.id, 'name', m.name,
                            'group_name', m.group_name, 'is_admin', m.is_admin);
end $$;

create or replace function log_preaching(
  p_member_id uuid, p_pin text, p_count integer,
  p_date date default current_date, p_note text default null)
returns uuid language plpgsql security definer as $$
declare m members; new_id uuid;
begin
  m := _auth(p_member_id, p_pin);
  if p_count is null or p_count < 1 then
    raise exception 'Count must be at least 1';
  end if;
  if p_date > current_date then
    raise exception 'That date is in the future';
  end if;
  insert into preaching_entries (member_id, entry_date, count, note)
       values (m.id, p_date, p_count, nullif(trim(p_note), ''))
    returning id into new_id;
  return new_id;
end $$;

-- Returns this member's own contacts with their current stage
-- and which stages are still legal to log.
create or replace function my_contacts(p_member_id uuid, p_pin text)
returns table (id uuid, name text, stage text, last_attended date, note text)
language plpgsql stable security definer as $$
declare m members;
begin
  m := _auth(p_member_id, p_pin);
  return query
    select c.id, c.name, f.stage, f.last_attended, c.note
      from contacts c
      join v_funnel f on f.contact_id = c.id
     where c.member_id = m.id
     order by c.created_at desc;
end $$;

-- Creates the contact when p_new_name is supplied, otherwise
-- advances an existing one. Enforces funnel order.
create or replace function log_contact_event(
  p_member_id uuid, p_pin text, p_event_type text,
  p_contact_id uuid default null, p_new_name text default null,
  p_date date default current_date, p_note text default null)
returns uuid language plpgsql security definer as $$
declare m members; cid uuid; has_valid boolean; has_baptism boolean; new_id uuid;
begin
  m := _auth(p_member_id, p_pin);

  if p_date > current_date then
    raise exception 'That date is in the future';
  end if;

  if p_contact_id is null then
    if p_event_type <> 'valid' then
      raise exception 'A new contact starts as valid';
    end if;
    if coalesce(trim(p_new_name), '') = '' then
      raise exception 'Give the contact a name';
    end if;
    insert into contacts (member_id, name) values (m.id, trim(p_new_name))
      returning id into cid;
  else
    select id into cid from contacts where id = p_contact_id and member_id = m.id;
    if cid is null then
      raise exception 'That contact is not yours';
    end if;
  end if;

  select exists (select 1 from contact_events where contact_id = cid and event_type = 'valid'),
         exists (select 1 from contact_events where contact_id = cid and event_type = 'baptism')
    into has_valid, has_baptism;

  if p_event_type = 'baptism' and not has_valid then
    raise exception 'Log a valid for this person first';
  end if;
  if p_event_type = 'attendance' and not has_baptism then
    raise exception 'Attendance follows baptism. Log the baptism first';
  end if;
  if p_event_type = 'valid' and has_valid then
    raise exception 'This person is already valid';
  end if;
  if p_event_type = 'baptism' and has_baptism then
    raise exception 'This person is already baptized';
  end if;

  insert into contact_events (contact_id, member_id, event_type, event_date, note)
       values (cid, m.id, p_event_type, p_date, nullif(trim(p_note), ''))
    returning id into new_id;
  return new_id;
end $$;

create or replace function my_history(p_member_id uuid, p_pin text, p_month date default null)
returns table (id uuid, kind text, category text, on_date date, count integer, who text, note text)
language plpgsql stable security definer as $$
declare m members; lo date; hi date;
begin
  m := _auth(p_member_id, p_pin);
  lo := coalesce(date_trunc('month', p_month)::date, '2000-01-01');
  hi := case when p_month is null then '2999-01-01'::date else (lo + interval '1 month')::date end;

  return query
    select e.id, 'preaching'::text, 'preaching'::text, e.entry_date, e.count, null::text, e.note
      from preaching_entries e
     where e.member_id = m.id and e.entry_date >= lo and e.entry_date < hi
    union all
    select ce.id, 'contact'::text, ce.event_type, ce.event_date, 1, c.name, ce.note
      from contact_events ce
      join contacts c on c.id = ce.contact_id
     where ce.member_id = m.id and ce.event_date >= lo and ce.event_date < hi
     order by 4 desc;
end $$;

create or replace function update_preaching(p_member_id uuid, p_pin text, p_id uuid, p_count integer, p_date date)
returns void language plpgsql security definer as $$
declare m members;
begin
  m := _auth(p_member_id, p_pin);
  update preaching_entries set count = p_count, entry_date = p_date
   where id = p_id and (member_id = m.id or m.is_admin);
  if not found then raise exception 'Entry not found'; end if;
end $$;

create or replace function delete_entry(p_member_id uuid, p_pin text, p_id uuid, p_kind text)
returns void language plpgsql security definer as $$
declare m members;
begin
  m := _auth(p_member_id, p_pin);
  if p_kind = 'preaching' then
    delete from preaching_entries where id = p_id and (member_id = m.id or m.is_admin);
  else
    delete from contact_events where id = p_id and (member_id = m.id or m.is_admin);
  end if;
  if not found then raise exception 'Entry not found'; end if;
end $$;

-- ------------------------------------------------------------
-- Admin RPCs
-- ------------------------------------------------------------

create or replace function admin_save_member(
  p_member_id uuid, p_pin text, p_name text, p_group text,
  p_new_pin text default null, p_is_admin boolean default false,
  p_target_id uuid default null)
returns uuid language plpgsql security definer as $$
declare m members; out_id uuid;
begin
  m := _auth(p_member_id, p_pin, true);
  if p_target_id is null then
    if coalesce(trim(p_new_pin), '') !~ '^\d{4}$' then
      raise exception 'PIN must be 4 digits';
    end if;
    insert into members (name, group_name, pin_hash, is_admin)
         values (trim(p_name), p_group, crypt(p_new_pin, gen_salt('bf')), p_is_admin)
      returning id into out_id;
  else
    update members
       set name = trim(p_name), group_name = p_group, is_admin = p_is_admin,
           pin_hash = case when coalesce(trim(p_new_pin), '') ~ '^\d{4}$'
                           then crypt(p_new_pin, gen_salt('bf')) else pin_hash end
     where id = p_target_id
      returning id into out_id;
  end if;
  return out_id;
end $$;

create or replace function admin_set_active(p_member_id uuid, p_pin text, p_target_id uuid, p_active boolean)
returns void language plpgsql security definer as $$
declare m members;
begin
  m := _auth(p_member_id, p_pin, true);
  if p_target_id = m.id and not p_active then
    raise exception 'You cannot deactivate yourself';
  end if;
  update members set is_active = p_active where id = p_target_id;
end $$;

create or replace function admin_set_goal(p_member_id uuid, p_pin text, p_group text, p_category text, p_target integer)
returns void language plpgsql security definer as $$
declare m members; this_month date := date_trunc('month', current_date)::date;
begin
  m := _auth(p_member_id, p_pin, true);
  delete from goals where group_name = p_group and category = p_category and effective_from = this_month;
  insert into goals (group_name, category, target, effective_from) values (p_group, p_category, p_target, this_month);
end $$;

create or replace function admin_set_points(p_member_id uuid, p_pin text, p_category text, p_points integer)
returns void language plpgsql security definer as $$
declare m members; this_month date := date_trunc('month', current_date)::date;
begin
  m := _auth(p_member_id, p_pin, true);
  delete from point_values where category = p_category and effective_from = this_month;
  insert into point_values (category, points, effective_from) values (p_category, p_points, this_month);
end $$;

create or replace function admin_export(p_member_id uuid, p_pin text)
returns table (member text, group_name text, on_date date, category text, count integer, who text, note text)
language plpgsql stable security definer as $$
declare m members;
begin
  m := _auth(p_member_id, p_pin, true);
  return query
    select mm.name, mm.group_name, e.entry_date, 'preaching'::text, e.count, null::text, e.note
      from preaching_entries e join members mm on mm.id = e.member_id
    union all
    select mm.name, mm.group_name, ce.event_date, ce.event_type, 1, c.name, ce.note
      from contact_events ce
      join members mm on mm.id = ce.member_id
      join contacts c on c.id = ce.contact_id
     order by 3 desc;
end $$;

-- ------------------------------------------------------------
-- First admin. Change the name and PIN, then delete this block
-- after the first run so it is not left in your SQL history.
-- ------------------------------------------------------------

insert into members (name, group_name, pin_hash, is_admin)
select 'Christian', 'evangelist', crypt('1234', gen_salt('bf')), true
 where not exists (select 1 from members);

-- ------------------------------------------------------------
-- Realtime
-- ------------------------------------------------------------

do $$
begin
  begin alter publication supabase_realtime add table preaching_entries; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table contact_events;    exception when duplicate_object then null; end;
end $$;
