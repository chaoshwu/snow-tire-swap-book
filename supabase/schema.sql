create table if not exists public.appointments (
  id uuid primary key default gen_random_uuid(),
  appointment_date date not null,
  appointment_time time without time zone not null,
  vehicle_year integer not null check (vehicle_year between 1980 and 2100),
  vehicle_make text not null,
  vehicle_model text not null,
  vehicle_trim text,
  location_type text not null check (location_type in ('home', 'second')),
  service_address text not null,
  customer_name text not null,
  customer_email text,
  customer_phone text not null,
  customer_phone_normalized text,
  request_ip text,
  created_at timestamptz not null default now(),
  archived_at timestamptz,
  constraint appointments_one_booking_per_slot unique (appointment_date, appointment_time)
);

alter table public.appointments alter column vehicle_trim drop not null;
alter table public.appointments alter column customer_email drop not null;
alter table public.appointments add column if not exists archived_at timestamptz;
alter table public.appointments add column if not exists customer_phone_normalized text;
alter table public.appointments add column if not exists request_ip text;

create index if not exists appointments_archived_date_idx
  on public.appointments (appointment_date, appointment_time, archived_at);
create index if not exists appointments_rate_limit_idx
  on public.appointments (created_at, customer_phone_normalized, request_ip);

alter table public.appointments enable row level security;
revoke all on table public.appointments from anon, authenticated;

create or replace function public.get_booked_slots(p_start_date date, p_end_date date)
returns table (appointment_date date, appointment_time time without time zone)
language sql
stable
security definer
set search_path = ''
as $$
  select a.appointment_date, a.appointment_time
  from public.appointments as a
  where a.appointment_date between p_start_date and p_end_date
    and a.archived_at is null
  order by a.appointment_date, a.appointment_time;
$$;

revoke all on function public.get_booked_slots(date, date) from public;
grant execute on function public.get_booked_slots(date, date) to anon, authenticated;

create or replace function public.archive_past_appointments()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  local_now timestamp without time zone;
  archived_count integer;
begin
  local_now := now() at time zone 'America/Toronto';

  update public.appointments
  set archived_at = now()
  where archived_at is null
    and (appointment_date + appointment_time) < local_now;

  get diagnostics archived_count = row_count;
  return archived_count;
end;
$$;

revoke all on function public.archive_past_appointments() from public;

create or replace view public.archived_appointments as
select *
from public.appointments
where archived_at is not null;

revoke all on public.archived_appointments from public;

create or replace function public.create_appointment(
  p_appointment_date date,
  p_appointment_time time without time zone,
  p_vehicle_year integer,
  p_vehicle_make text,
  p_vehicle_model text,
  p_vehicle_trim text,
  p_location_type text,
  p_service_address text,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_appointment_id uuid;
  appointment_weekday integer;
  local_today date;
  local_now timestamp without time zone;
  request_headers jsonb;
  request_ip_value text;
  normalized_phone text;
  recent_booking_count integer;
begin
  -- Supabase runs in UTC by default, while the booking calendar is local to Toronto.
  -- Use the service area's date so late-evening bookings for tomorrow are accepted.
  local_today := (now() at time zone 'America/Toronto')::date;
  local_now := now() at time zone 'America/Toronto';
  normalized_phone := regexp_replace(coalesce(p_customer_phone, ''), '[^0-9]', '', 'g');
  request_headers := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
  request_ip_value := nullif(trim(split_part(
    coalesce(nullif(request_headers ->> 'x-forwarded-for', ''), request_headers ->> 'x-real-ip', ''),
    ',',
    1
  )), '');

  if p_appointment_date is null or p_appointment_time is null then
    raise exception 'Choose an appointment date and time.' using errcode = '22023';
  end if;

  appointment_weekday := extract(isodow from p_appointment_date)::integer;
  if p_appointment_date < local_today
    or p_appointment_date > make_date(extract(year from local_today)::integer, 12, 31)
    or not (
      (appointment_weekday between 3 and 5 and p_appointment_time = time '17:00')
      or (appointment_weekday in (6, 7) and p_appointment_time >= time '08:00' and p_appointment_time <= time '17:00')
    )
    or extract(minute from p_appointment_time) <> 0
    or extract(second from p_appointment_time) <> 0
    or (p_appointment_date + p_appointment_time) < (local_now + interval '1 hour') then
    raise exception 'This appointment time is outside the available schedule.' using errcode = '22023';
  end if;

  if p_vehicle_year is null
    or nullif(btrim(p_vehicle_make), '') is null
    or nullif(btrim(p_vehicle_model), '') is null
    or p_location_type not in ('home', 'second')
    or nullif(btrim(p_service_address), '') is null
    or nullif(btrim(p_customer_name), '') is null
    or nullif(btrim(p_customer_phone), '') is null then
    raise exception 'Complete all required booking details.' using errcode = '22023';
  end if;

  -- Serialize requests sharing either identifier so concurrent submissions cannot
  -- bypass the limit at the same time.
  perform pg_catalog.pg_advisory_xact_lock(hashtextextended('phone:' || normalized_phone, 0));
  if request_ip_value is not null then
    perform pg_catalog.pg_advisory_xact_lock(hashtextextended('ip:' || request_ip_value, 0));
  end if;

  select count(*) into recent_booking_count
  from public.appointments as a
  where a.created_at >= now() - interval '24 hours'
    and (
      a.customer_phone_normalized = normalized_phone
      or (request_ip_value is not null and a.request_ip = request_ip_value)
    );

  if recent_booking_count >= 4 then
    raise exception 'Booking limit reached: this phone number or IP address can make up to 4 successful bookings in 24 hours.'
      using errcode = 'P0001';
  end if;

  insert into public.appointments (
    appointment_date,
    appointment_time,
    vehicle_year,
    vehicle_make,
    vehicle_model,
    vehicle_trim,
    location_type,
    service_address,
    customer_name,
    customer_email,
    customer_phone,
    customer_phone_normalized,
    request_ip
  ) values (
    p_appointment_date,
    p_appointment_time,
    p_vehicle_year,
    btrim(p_vehicle_make),
    btrim(p_vehicle_model),
    nullif(btrim(coalesce(p_vehicle_trim, '')), ''),
    p_location_type,
    btrim(p_service_address),
    btrim(p_customer_name),
    nullif(btrim(coalesce(p_customer_email, '')), ''),
    btrim(p_customer_phone),
    normalized_phone,
    request_ip_value
  ) returning id into new_appointment_id;

  return new_appointment_id;
end;
$$;

revoke all on function public.create_appointment(date, time without time zone, integer, text, text, text, text, text, text, text, text) from public;
grant execute on function public.create_appointment(date, time without time zone, integer, text, text, text, text, text, text, text, text) to anon, authenticated;
