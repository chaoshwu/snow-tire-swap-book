type AppointmentRecord = {
  id: string;
  appointment_date: string;
  appointment_time: string;
  vehicle_year: number;
  vehicle_make: string;
  vehicle_model: string;
  vehicle_trim: string | null;
  vehicle_2_year: number | null;
  vehicle_2_make: string | null;
  vehicle_2_model: string | null;
  vehicle_2_trim: string | null;
  location_type: string;
  service_address: string;
  customer_name: string;
  customer_email: string | null;
  customer_phone: string;
};

type DatabaseWebhookPayload = {
  type: string;
  schema: string;
  table: string;
  record: AppointmentRecord | null;
};

function jsonResponse(message: string, status: number): Response {
  return new Response(JSON.stringify({ message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return jsonResponse("Method not allowed.", 405);
  }

  const webhookSecret = Deno.env.get("BOOKING_WEBHOOK_SECRET");
  if (!webhookSecret || request.headers.get("x-webhook-secret") !== webhookSecret) {
    return jsonResponse("Unauthorized.", 401);
  }

  let payload: DatabaseWebhookPayload;
  try {
    payload = await request.json();
  } catch {
    return jsonResponse("Invalid JSON payload.", 400);
  }

  if (payload.type !== "INSERT" || payload.schema !== "public" || payload.table !== "appointments" || !payload.record) {
    return jsonResponse("Unexpected database webhook payload.", 400);
  }

  const appointment = payload.record;
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  const notificationEmail = Deno.env.get("BOOKING_NOTIFICATION_EMAIL");
  const senderEmail = Deno.env.get("BOOKING_EMAIL_FROM");

  if (!resendApiKey || !notificationEmail || !senderEmail) {
    console.error("Booking email secrets are not configured.");
    return jsonResponse("Email service is not configured.", 500);
  }

  const time = appointment.appointment_time.slice(0, 5);
  const vehicle = [
    appointment.vehicle_year,
    appointment.vehicle_make,
    appointment.vehicle_model,
    appointment.vehicle_trim,
  ].filter(Boolean).join(" ");
  const secondVehicle = [
    appointment.vehicle_2_year,
    appointment.vehicle_2_make,
    appointment.vehicle_2_model,
    appointment.vehicle_2_trim,
  ].filter(Boolean).join(" ");
  const emailLines = [
    "A new tire-change appointment was booked.",
    "",
    `Date: ${appointment.appointment_date}`,
    `Time: ${time}`,
    `Vehicle: ${vehicle}`,
    ...(secondVehicle ? [`Vehicle 2: ${secondVehicle}`] : []),
    `Service location: ${appointment.location_type}`,
    `Address: ${appointment.service_address}`,
    `Customer: ${appointment.customer_name}`,
    `Phone: ${appointment.customer_phone}`,
    `Email: ${appointment.customer_email || "Not provided"}`,
    `Booking ID: ${appointment.id}`,
  ];

  const emailResponse = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
      "Idempotency-Key": `booking-${appointment.id}`,
    },
    body: JSON.stringify({
      from: senderEmail,
      to: [notificationEmail],
      reply_to: appointment.customer_email || undefined,
      subject: `New tire appointment: ${appointment.appointment_date} ${time}`,
      text: emailLines.join("\n"),
    }),
  });

  if (!emailResponse.ok) {
    console.error("Resend rejected booking email with status", emailResponse.status);
    return jsonResponse("Email provider rejected the notification.", 502);
  }

  return jsonResponse("Booking notification sent.", 200);
});
