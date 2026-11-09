alter table public.appointments
  add column if not exists service_type text,
  add column if not exists oil_vin text,
  add column if not exists oil_materials text;

update public.appointments
set service_type = 'tire'
where service_type is null;

alter table public.appointments
  alter column service_type set default 'tire',
  alter column service_type set not null;

do $$
declare
  constraint_row record;
begin
  for constraint_row in
    select conname
    from pg_catalog.pg_constraint
    where conrelid = 'public.appointments'::regclass
      and contype = 'c'
      and pg_catalog.pg_get_constraintdef(oid) ilike '%service_type%'
  loop
    execute pg_catalog.format('alter table public.appointments drop constraint %I', constraint_row.conname);
  end loop;
end;
$$;

alter table public.appointments
  add constraint appointments_service_type_check
  check (service_type in ('tire', 'oil', 'both'));

create or replace function public.create_appointment_v4(
  p_appointment_date date,
  p_appointment_time time without time zone,
  p_vehicle_year integer,
  p_vehicle_make text,
  p_vehicle_model text,
  p_vehicle_trim text,
  p_vehicle_2_year integer,
  p_vehicle_2_make text,
  p_vehicle_2_model text,
  p_vehicle_2_trim text,
  p_vehicle_2_time time without time zone,
  p_location_type text,
  p_service_address text,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text,
  p_service_type text,
  p_oil_vin text,
  p_oil_materials text
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
  has_second_vehicle boolean;
  is_oil_service boolean;
  is_combined_service boolean;
  reserves_second_slot boolean;
  second_slot_time time without time zone;
begin
  local_today := (now() at time zone 'America/Toronto')::date;
  local_now := now() at time zone 'America/Toronto';
  appointment_weekday := extract(isodow from p_appointment_date)::integer;
  has_second_vehicle := p_vehicle_2_year is not null;
  is_oil_service := p_service_type in ('oil', 'both');
  is_combined_service := p_service_type = 'both';
  reserves_second_slot := is_combined_service
    or (has_second_vehicle and appointment_weekday in (6, 7));
  second_slot_time := p_vehicle_2_time;
  normalized_phone := regexp_replace(coalesce(p_customer_phone, ''), '[^0-9]', '', 'g');
  request_headers := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
  request_ip_value := nullif(trim(split_part(
    coalesce(nullif(request_headers ->> 'x-forwarded-for', ''), request_headers ->> 'x-real-ip', ''), ',', 1)), '');

  if p_appointment_date is null or p_appointment_time is null
    or p_appointment_date < local_today
    or p_appointment_date > make_date(extract(year from local_today)::integer, 12, 31)
    or not ((appointment_weekday between 3 and 5 and p_appointment_time = time '17:00')
      or (appointment_weekday in (6, 7) and (
        p_appointment_time between time '08:00' and time '11:00'
        or p_appointment_time between time '13:00' and time '16:00'
      )))
    or extract(minute from p_appointment_time) <> 0
    or extract(second from p_appointment_time) <> 0
    or (p_appointment_date + p_appointment_time) < (local_now + interval '1 hour') then
    raise exception 'This appointment time is outside the available schedule.' using errcode = '22023';
  end if;

  if p_service_type is null or p_service_type not in ('tire', 'oil', 'both') then
    raise exception 'Choose a valid service.' using errcode = '22023';
  end if;

  if is_combined_service and (has_second_vehicle or appointment_weekday not in (6, 7)) then
    raise exception 'Combined tire and oil service requires one vehicle and two consecutive weekend slots.' using errcode = '22023';
  end if;

  if has_second_vehicle and (
    p_vehicle_2_make is null or nullif(btrim(p_vehicle_2_make), '') is null
    or p_vehicle_2_model is null or nullif(btrim(p_vehicle_2_model), '') is null
    or p_service_type <> 'tire'
    or (appointment_weekday between 3 and 5 and p_vehicle_2_time <> p_appointment_time)
    or (appointment_weekday in (6, 7) and (
      p_vehicle_2_time <> p_appointment_time + interval '1 hour'
      or p_vehicle_2_time = time '12:00'
      or p_vehicle_2_time > time '16:00'
    ))
  ) then
    raise exception 'Two vehicles require tire service and valid consecutive weekend slots.' using errcode = '22023';
  end if;

  if reserves_second_slot and (
    p_vehicle_2_time is null
    or p_vehicle_2_time <> p_appointment_time + interval '1 hour'
    or (is_combined_service and p_appointment_time not in (time '08:00', time '09:00', time '10:00', time '13:00', time '14:00', time '15:00', time '16:00'))
    or (has_second_vehicle and p_appointment_time not in (time '08:00', time '09:00', time '10:00', time '13:00', time '14:00', time '15:00'))
  ) then
    raise exception 'This service requires two consecutive available weekend slots.' using errcode = '22023';
  end if;

  if p_vehicle_year is null
    or nullif(btrim(coalesce(p_vehicle_make, '')), '') is null
    or nullif(btrim(coalesce(p_vehicle_model, '')), '') is null
    or (is_oil_service and nullif(btrim(coalesce(p_vehicle_trim, '')), '') is null)
    or p_location_type is null or p_location_type not in ('home', 'second')
    or nullif(btrim(coalesce(p_service_address, '')), '') is null
    or nullif(btrim(coalesce(p_customer_name, '')), '') is null
    or nullif(btrim(coalesce(p_customer_phone, '')), '') is null then
    raise exception 'Complete all required booking details.' using errcode = '22023';
  end if;

  if has_second_vehicle is false and (
    p_vehicle_2_make is not null or p_vehicle_2_model is not null or p_vehicle_2_trim is not null
  ) then
    raise exception 'Vehicle 2 details are incomplete.' using errcode = '22023';
  end if;

  if is_oil_service then
    if p_oil_materials not in ('customer', 'shop') then
      raise exception 'Choose who will provide the oil and filter.' using errcode = '22023';
    end if;
    if p_oil_materials = 'shop' and coalesce(btrim(p_oil_vin), '') !~ '^[A-HJ-NPR-Z0-9]{17}$' then
      raise exception 'Enter a valid 17-character VIN for sourcing.' using errcode = '22023';
    end if;
  elsif p_oil_vin is not null or p_oil_materials is not null then
    raise exception 'Oil details are only valid for oil service.' using errcode = '22023';
  end if;

  -- Lock both slots in chronological order so simultaneous submissions cannot overlap.
  perform pg_catalog.pg_advisory_xact_lock(hashtextextended(
    'appointment-slot:' || p_appointment_date::text || ':' || p_appointment_time::text, 0));
  if reserves_second_slot then
    perform pg_catalog.pg_advisory_xact_lock(hashtextextended(
      'appointment-slot:' || p_appointment_date::text || ':' || second_slot_time::text, 0));
  end if;

  if exists (
    select 1 from public.appointments as a
    where a.appointment_date = p_appointment_date
      and a.appointment_time = p_appointment_time
      and a.archived_at is null
  ) or exists (
    select 1 from public.booking_slots as s
    join public.appointments as a on a.id = s.appointment_id
    where s.appointment_date = p_appointment_date
      and s.appointment_time = p_appointment_time
      and a.archived_at is null
  ) then
    raise exception 'This slot was just booked. Choose another time.' using errcode = '23505';
  end if;

  if reserves_second_slot and (
    exists (
      select 1 from public.appointments as a
      where a.appointment_date = p_appointment_date
        and a.appointment_time = second_slot_time
        and a.archived_at is null
    ) or exists (
      select 1 from public.booking_slots as s
      join public.appointments as a on a.id = s.appointment_id
      where s.appointment_date = p_appointment_date
        and s.appointment_time = second_slot_time
        and a.archived_at is null
    )
  ) then
    raise exception 'This slot was just booked. Choose another time.' using errcode = '23505';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(hashtextextended('phone:' || normalized_phone, 0));
  if request_ip_value is not null then
    perform pg_catalog.pg_advisory_xact_lock(hashtextextended('ip:' || request_ip_value, 0));
  end if;

  select count(*) into recent_booking_count
  from public.appointments as a
  where a.created_at >= now() - interval '24 hours'
    and (a.customer_phone_normalized = normalized_phone
      or (request_ip_value is not null and a.request_ip = request_ip_value));
  if recent_booking_count >= 4 then
    raise exception 'Booking limit reached: this phone number or IP address can make up to 4 successful bookings in 24 hours.'
      using errcode = 'P0001';
  end if;

  insert into public.appointments (
    appointment_date, appointment_time,
    vehicle_year, vehicle_make, vehicle_model, vehicle_trim,
    vehicle_2_year, vehicle_2_make, vehicle_2_model, vehicle_2_trim,
    location_type, service_address, customer_name, customer_email, customer_phone,
    customer_phone_normalized, request_ip, service_type, oil_vin, oil_materials
  ) values (
    p_appointment_date, p_appointment_time,
    p_vehicle_year, btrim(p_vehicle_make), btrim(p_vehicle_model), nullif(btrim(coalesce(p_vehicle_trim, '')), ''),
    p_vehicle_2_year, nullif(btrim(p_vehicle_2_make), ''), nullif(btrim(p_vehicle_2_model), ''), nullif(btrim(coalesce(p_vehicle_2_trim, '')), ''),
    p_location_type, btrim(p_service_address), btrim(p_customer_name), nullif(btrim(coalesce(p_customer_email, '')), ''), btrim(p_customer_phone),
    normalized_phone, request_ip_value, p_service_type,
    case when is_oil_service then nullif(upper(btrim(coalesce(p_oil_vin, ''))), '') else null end,
    case when is_oil_service then p_oil_materials else null end
  ) returning id into new_appointment_id;

  if reserves_second_slot then
    insert into public.booking_slots (appointment_id, appointment_date, appointment_time)
    values (new_appointment_id, p_appointment_date, second_slot_time);
  end if;

  return new_appointment_id;
end;
$$;

revoke all on function public.create_appointment_v4(date, time without time zone, integer, text, text, text, integer, text, text, text, time without time zone, text, text, text, text, text, text, text, text) from public;
grant execute on function public.create_appointment_v4(date, time without time zone, integer, text, text, text, integer, text, text, text, time without time zone, text, text, text, text, text, text, text, text) to anon, authenticated;
