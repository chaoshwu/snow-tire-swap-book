# Supabase setup

## 1. Create a project

Create a Supabase project at https://supabase.com/dashboard and choose the region closest to the service area.

## 2. Create the database objects

In the Supabase dashboard, open **SQL Editor**, create a query, paste the contents of `supabase/schema.sql`, and run it. If the earlier schema is already installed, run this updated SQL again; it keeps existing appointments and makes trim and email optional. The database accepts future appointments through December 31 of the current year. This creates a private appointments table, an archive marker, and RPC functions:

- `get_booked_slots` returns only occupied dates and times. It does not expose customer details.
- `create_appointment` validates the schedule and inserts the booking. A unique database constraint prevents two bookings for the same slot.
- `archive_past_appointments` marks appointments whose scheduled time has passed with `archived_at`; it does not delete any data.
- `archived_appointments` is a private view for historical analysis. Query it from the Supabase SQL Editor or another authenticated admin backend.
- `create_appointment` limits successful bookings to 4 per phone number or source IP address in any rolling 24-hour window.

### Automatic archiving

The archive function is intentionally not callable by the public booking page. To run it automatically, enable the `pg_cron` extension in Supabase, then run this once in the SQL Editor:

```sql
select cron.schedule(
  'archive-past-appointments',
  '15 0 * * *',
  $$select public.archive_past_appointments();$$
);
```

Run `select public.archive_past_appointments();` once after installing the updated schema to archive any history that already exists.

This checks once per day at 00:15 in the database timezone. The function itself uses `America/Toronto` time when deciding which appointments are past. Historical rows remain available through `public.archived_appointments` for analysis.

## 3. Connect the page

In **Project Settings > API** (or the project's API/connect panel), copy the **Project URL** and the **anon / publishable key** into `supabase-config.js`:

```js
window.SUPABASE_CONFIG = {
  url: "https://YOUR_PROJECT_REF.supabase.co",
  anonKey: "YOUR_PUBLIC_ANON_KEY"
};
```

The anon/publishable key is designed for browser use. Never put the `service_role` key, database password, or email-provider secret in this file or any frontend code.

The booking function uses `America/Toronto` for the date boundary, so it stays aligned with the calendar shown to customers even when Supabase's default UTC date has already advanced.

## 4. Test

Serve the workspace over `http://localhost` (not `file://`), then test booking the same date and time twice. The first request should be saved; the second should be rejected by the database unique constraint. Check the `appointments` table in the Supabase dashboard to review submitted details.

## Current limits

## Email notifications

The `smooth-api` Edge Function at `supabase/functions/smooth-api/index.ts` sends a plain-text notification to the shop after a new appointment is inserted. It uses Resend; the API key and shop inbox stay in Supabase secrets, not in the website.

1. Create a Resend account and an API key. For regular delivery, verify a sending domain and choose a sender such as `Northline Tire <bookings@yourdomain.com>`.
2. In Supabase **Edge Functions > Secrets**, add these secrets:

  - `RESEND_API_KEY`: your Resend API key.
  - `BOOKING_NOTIFICATION_EMAIL`: the email inbox that should receive booking alerts.
  - `BOOKING_EMAIL_FROM`: the sender identity authorized in Resend.
  - `BOOKING_WEBHOOK_SECRET`: a long random value you generate; use the same value in the database webhook header below.

3. Deploy the function. The Dashboard route does not require a local CLI:

  - In **Edge Functions**, open the existing `smooth-api` function and use **Code > Deploy updates**.
  - Paste the contents of `supabase/functions/smooth-api/index.ts` into the editor.
  - Turn off JWT verification for this function. It authenticates the database webhook with `x-webhook-secret` instead.
  - Click **Deploy function**.

  Alternatively, deploy with the Supabase CLI:

  ```sh
  supabase login
  supabase link --project-ref YOUR_PROJECT_REF
  supabase functions deploy smooth-api --no-verify-jwt
  ```

  JWT verification is disabled because the database webhook authenticates with the shared `x-webhook-secret` header instead.

4. In Supabase **Database > Webhooks**, create a webhook for `public.appointments`, event **INSERT**, method **POST**, URL `https://YOUR_PROJECT_REF.supabase.co/functions/v1/smooth-api`. Add the header `x-webhook-secret` with the same random value saved as `BOOKING_WEBHOOK_SECRET`.

5. Make a test booking with dummy customer details, then check the shop inbox and **Edge Functions > Logs**. The email includes the vehicle, appointment time, service address, and customer contact details. The customer's email is optional and is only used as the reply-to address when supplied.

The booking is saved even if the asynchronous email webhook later fails; check webhook/function logs if a notification does not arrive. Never put the Resend key, shared webhook secret, or Supabase `service_role` key in frontend files. Before sharing publicly, add abuse protection such as Cloudflare Turnstile and a server-side rate limit to the public booking submission.
