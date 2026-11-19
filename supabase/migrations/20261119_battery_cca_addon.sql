alter table public.appointments
  add column if not exists battery_cca_test boolean not null default false;

create or replace function public.apply_booking_fee_details()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  details jsonb := nullif(current_setting('app.booking_fee_details', true), '')::jsonb;
  battery_cca_test text := nullif(current_setting('app.booking_battery_cca_test', true), '');
begin
  if details is not null then
    new.fee_vehicle_1_status := details ->> 'vehicle_1';
    new.fee_vehicle_2_status := details ->> 'vehicle_2';
    new.fee_distance_km := (details ->> 'distance_km')::numeric;
  end if;
  if battery_cca_test is not null then
    new.battery_cca_test := battery_cca_test::boolean;
  end if;
  return new;
end;
$$;

create or replace function public.create_appointment_v6(
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
  p_fee_distance_km numeric,
  p_battery_cca_test boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  appointment_id uuid;
begin
  if p_battery_cca_test is null then
    raise exception 'Invalid battery CCA test selection.' using errcode = '22023';
  end if;

  perform pg_catalog.set_config('app.booking_battery_cca_test', p_battery_cca_test::text, true);

  appointment_id := public.create_appointment_v5(
    p_appointment_date, p_appointment_time,
    p_vehicle_year, p_vehicle_make, p_vehicle_model, p_vehicle_trim,
    p_vehicle_2_year, p_vehicle_2_make, p_vehicle_2_model, p_vehicle_2_trim,
    p_vehicle_2_time, p_location_type, p_service_address,
    p_customer_name, p_customer_email, p_customer_phone,
    p_service_type, p_oil_vin, p_oil_materials,
    p_fee_vehicle_1_status, p_fee_vehicle_2_status, p_fee_distance_km
  );
  perform pg_catalog.set_config('app.booking_battery_cca_test', '', true);
  return appointment_id;
end;
$$;

revoke all on function public.create_appointment_v6(date, time without time zone, integer, text, text, text, integer, text, text, text, time without time zone, text, text, text, text, text, text, text, text, text, text, numeric, boolean) from public;
grant execute on function public.create_appointment_v6(date, time without time zone, integer, text, text, text, integer, text, text, text, time without time zone, text, text, text, text, text, text, text, text, text, text, numeric, boolean) to anon, authenticated;
