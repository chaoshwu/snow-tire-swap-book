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

function escapeHtml(value: string): string {
  const escapedCharacters: Record<string, string> = {
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  };
  return value.replace(/[&<>"']/g, (character) => escapedCharacters[character]);
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
  const customerPhone = appointment.customer_phone?.trim() || "Not provided";
  const customerEmail = appointment.customer_email?.trim() || "Not provided";
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
  const emailDetails: Array<{ label: string; value: string }> = [
    { label: "Date", value: appointment.appointment_date },
    { label: "Time", value: time },
    { label: "Vehicle", value: vehicle },
    { label: "Service location", value: appointment.location_type },
    { label: "Address", value: appointment.service_address },
    { label: "Customer", value: appointment.customer_name },
    { label: "Phone", value: customerPhone },
    { label: "Email", value: customerEmail },
  ];
  if (secondVehicle) emailDetails.splice(3, 0, { label: "Vehicle 2", value: secondVehicle });

  const emailLines = [
    "NEW TIRE-CHANGE APPOINTMENT",
    "",
    ...emailDetails.map(({ label, value }) => `${label}: ${value}`),
  ];
  const emailRows = emailDetails.map(({ label, value }) => `
    <tr>
      <th align="left" style="padding: 10px 12px; border-bottom: 1px solid #e8e8e3; color: #53604c; font-size: 13px; font-weight: 600; white-space: nowrap;">${escapeHtml(label)}</th>
      <td style="padding: 10px 12px; border-bottom: 1px solid #e8e8e3; color: #252820; font-size: 14px;">${escapeHtml(value)}</td>
    </tr>`).join("");
  const emailHtml = `<!doctype html>
<html>
  <body style="margin: 0; padding: 24px; background: #f5f6f2; font-family: Arial, Helvetica, sans-serif; color: #252820;">
    <div style="max-width: 640px; margin: 0 auto; padding: 24px; border: 1px solid #e8e8e3; border-radius: 12px; background: #ffffff;">
      <h1 style="margin: 0 0 18px; color: #33432e; font-size: 20px;">New tire-change appointment</h1>
      <table role="presentation" style="width: 100%; border-collapse: collapse;">${emailRows}
      </table>
    </div>
  </body>
</html>`;

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
      html: emailHtml,
    }),
  });

  if (!emailResponse.ok) {
    console.error("Resend rejected booking email with status", emailResponse.status);
    return jsonResponse("Email provider rejected the notification.", 502);
  }

  return jsonResponse("Booking notification sent.", 200);
});
