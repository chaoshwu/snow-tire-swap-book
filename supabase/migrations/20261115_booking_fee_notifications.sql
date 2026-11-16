alter table public.appointments
  add column if not exists fee_vehicle_1_status text,
  add column if not exists fee_vehicle_2_status text,
  add column if not exists fee_distance_km numeric;

create or replace function public.apply_booking_fee_details()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  details jsonb := nullif(current_setting('app.booking_fee_details', true), '')::jsonb;
begin
  if details is not null then
    new.fee_vehicle_1_status := details ->> 'vehicle_1';
    new.fee_vehicle_2_status := details ->> 'vehicle_2';
    new.fee_distance_km := (details ->> 'distance_km')::numeric;
  end if;
  return new;
end;
$$;

create or replace trigger appointments_apply_booking_fee_details
before insert on public.appointments
for each row execute function public.apply_booking_fee_details();

revoke all on function public.apply_booking_fee_details() from public;

create or replace function public.create_appointment_v5(
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
  p_oil_materials text,
  p_fee_vehicle_1_status text,
  p_fee_vehicle_2_status text,
  p_fee_distance_km numeric
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  appointment_id uuid;
begin
  if p_fee_vehicle_1_status is null or p_fee_vehicle_1_status not in ('standard', 'surcharge', 'review')
    or (p_vehicle_2_year is null and p_fee_vehicle_2_status is not null)
    or (p_vehicle_2_year is not null and (p_fee_vehicle_2_status is null or p_fee_vehicle_2_status not in ('standard', 'surcharge', 'review')))
    or (p_fee_distance_km is not null and (p_fee_distance_km < 0 or p_fee_distance_km > 15)) then
    raise exception 'Invalid booking fee details.' using errcode = '22023';
  end if;

  perform pg_catalog.set_config('app.booking_fee_details', jsonb_build_object(
    'vehicle_1', p_fee_vehicle_1_status,
    'vehicle_2', p_fee_vehicle_2_status,
    'distance_km', p_fee_distance_km
  )::text, true);

  appointment_id := public.create_appointment_v4(
    p_appointment_date, p_appointment_time,
    p_vehicle_year, p_vehicle_make, p_vehicle_model, p_vehicle_trim,
    p_vehicle_2_year, p_vehicle_2_make, p_vehicle_2_model, p_vehicle_2_trim,
    p_vehicle_2_time, p_location_type, p_service_address,
    p_customer_name, p_customer_email, p_customer_phone,
    p_service_type, p_oil_vin, p_oil_materials
  );
  perform pg_catalog.set_config('app.booking_fee_details', '', true);
  return appointment_id;
end;
$$;

revoke all on function public.create_appointment_v5(date, time without time zone, integer, text, text, text, integer, text, text, text, time without time zone, text, text, text, text, text, text, text, text, text, text, numeric) from public;
grant execute on function public.create_appointment_v5(date, time without time zone, integer, text, text, text, integer, text, text, text, time without time zone, text, text, text, text, text, text, text, text, text, text, numeric) to anon, authenticated;
