# Sending mail from backend services

Give every application its own mailbox, for example `no-reply@a.com`. Never
reuse a person's mailbox: you cannot rotate its password without locking someone
out, and a leaked application credential would expose their mail.

| Setting | Value |
|---|---|
| Host | `mail.example.com` (the same host for every domain) |
| Port | `587` with STARTTLS, or `465` with implicit TLS |
| Username | the full email address, e.g. `no-reply@a.com` |
| Password | that mailbox's password |
| Encryption | required — unauthenticated submission is refused with `530` |

Both ports are equivalent in security. Use 465 if your library supports implicit
TLS cleanly, otherwise 587.

## PHP (PHPMailer)

```php
$mail = new PHPMailer\PHPMailer\PHPMailer(true);
$mail->isSMTP();
$mail->Host       = getenv('MAIL_HOST');
$mail->SMTPAuth   = true;
$mail->Username   = getenv('MAIL_USERNAME');
$mail->Password   = getenv('MAIL_PASSWORD');
$mail->SMTPSecure = PHPMailer\PHPMailer\PHPMailer::ENCRYPTION_STARTTLS;
$mail->Port       = 587;

$mail->setFrom(getenv('MAIL_USERNAME'), 'A.com Support');
$mail->addAddress('customer@example.org');
$mail->Subject = 'Order confirmed';
$mail->Body    = 'Thanks for your order.';
$mail->send();
```

## Laravel

```ini
MAIL_MAILER=smtp
MAIL_HOST=mail.example.com
MAIL_PORT=587
MAIL_USERNAME=no-reply@a.com
MAIL_PASSWORD=...
MAIL_ENCRYPTION=tls
MAIL_FROM_ADDRESS=no-reply@a.com
```

## Node.js (Nodemailer)

```js
const nodemailer = require("nodemailer");

const transport = nodemailer.createTransport({
  host: process.env.MAIL_HOST,
  port: 465,
  secure: true, // implicit TLS
  auth: {
    user: process.env.MAIL_USERNAME,
    pass: process.env.MAIL_PASSWORD,
  },
});

await transport.sendMail({
  from: '"B.com" <no-reply@b.com>',
  to: "customer@example.org",
  subject: "Password reset",
  text: "Use the link below to reset your password.",
});
```

Read credentials from the application's own environment or secret store. Never
commit them, and never put the Mailu `API_TOKEN` in an application that only
needs to send mail.

## Sending as several domains from one account

By default a mailbox may only send using its own address. To let one shared
sender use addresses across all your domains, add it to `WILDCARD_SENDERS` in
`mailu.env`:

```ini
WILDCARD_SENDERS=no-reply@a.com
```

That account can then spoof any sender address on the server, so treat its
password as a high-value secret. Separate per-domain accounts are safer.

## Rate limits

`MESSAGE_RATELIMIT` (default `200/day`) applies per user and exists to contain
the damage from a compromised account. Applications that legitimately send more
should be listed in `MESSAGE_RATELIMIT_EXEMPTION` rather than having the global
limit raised.

## Managing mailboxes over the REST API

Enable with `API=true` and a strong `API_TOKEN` in `mailu.env`. The token grants
full administrative control over every domain, so it belongs only in your
provisioning system.

```bash
TOKEN=$(grep '^API_TOKEN=' mailu.env | cut -d= -f2)

curl -X POST https://mail.example.com/api/v1/domain \
  -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"c.com"}'

curl -X POST https://mail.example.com/api/v1/user \
  -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"email":"info@c.com","raw_password":"...","global_admin":false}'

# Generate DKIM keys, then read back the DNS records to publish
curl -X POST https://mail.example.com/api/v1/domain/c.com/dkim -H "Authorization: $TOKEN"
curl https://mail.example.com/api/v1/domain/c.com -H "Authorization: $TOKEN"
```

Requests without a valid token return `401`. Interactive documentation is served
at `https://mail.example.com/api/`.

Leave `global_admin` false for ordinary mailboxes. Only global admins can see
the list of hosted domains; a normal user sees no domain listing at all and
receives `403` on administrative pages.
