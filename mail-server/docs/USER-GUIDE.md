# User guide

For people with a mailbox on the server. Everything here is done at
`https://mail.example.com/` — replace that with whatever address your
administrator gave you.

---

## Signing in

Go to `https://mail.example.com/` and sign in with your **full email address**
(`you@yourdomain.com`, not just `you`) and your password.

You land on your account page. **Go to Webmail** opens your mail.

If you were given a temporary password, you are asked to change it on first
sign-in. That is normal.

---

## Reading and sending mail in the browser

Webmail is Roundcube, at `/webmail`.

| Task | How |
|---|---|
| Read mail | **Inbox** in the left column; click a message |
| Write | **Compose** |
| Attach | the paperclip while composing |
| Search | the box above the message list; it searches subject and sender by default |
| Folders | right-click the folder list to create, rename or delete |
| Contacts | **Contacts** in the top bar |
| Signature | Settings → Identities → your address |

Deleted mail goes to **Trash** and is not gone until Trash is emptied.

---

## Your account settings

Reachable from your address in the top-right corner.

| Page | Path | What it does |
|---|---|---|
| Settings | `/admin/user/settings` | display name, spam threshold, forwarding |
| Update password | `/admin/user/password` | change your password |
| Auto-reply | `/admin/user/reply` | out-of-office message with a start and end date |
| Authentication tokens | `/admin/token/list` | app-specific passwords, see below |
| Client setup | `/admin/client` | the exact settings for your mail app |

You will not see a Domains section. That is intentional — the server hosts
several unrelated domains and users only ever see their own account.

### Auto-reply

Set the message and a date range, then enable it. It replies once per sender
rather than to every message, so it will not start a loop.

### Authentication tokens

A token is a separate password for one application, which you can revoke without
changing your real password. Useful for a phone or a script. Create one, copy it
immediately — it is shown only once — and use it in place of your password.

---

## Setting up a mail app

Use these on a phone, Outlook, Thunderbird, or Apple Mail. `/admin/client` shows
them filled in with your own address.

**Incoming — IMAP**

| Setting | Value |
|---|---|
| Server | `mail.example.com` |
| Port | **993** |
| Security | SSL/TLS |
| Username | your full email address |
| Password | your password (or an authentication token) |

**Outgoing — SMTP**

| Setting | Value |
|---|---|
| Server | `mail.example.com` |
| Port | **465** (SSL/TLS) — or **587** with STARTTLS |
| Security | SSL/TLS, or STARTTLS on 587 |
| Username | your full email address |
| Password | same as incoming |
| Authentication | required |

Three things that trip people up:

- The username is the **whole address**. `john` will not authenticate; `john@yourdomain.com` will.
- Outgoing mail needs authentication. Apps that leave it off get
  `530 Authentication required`.
- Use IMAP, not POP3, if you read mail on more than one device. POP3 downloads
  and removes; IMAP keeps everything on the server in sync.

On iOS and macOS, `/admin/client` offers a profile that configures Mail for you.

---

## When something is wrong

| Symptom | Likely cause |
|---|---|
| "Invalid email address" when signing in | you typed the username without the domain |
| Password rejected in a mail app but works in webmail | username missing the domain, or the app needs a token |
| Cannot send, "Authentication required" | outgoing authentication is off in the app |
| Cannot send, connection refused | wrong port — use 465 or 587, not 25 |
| Mail sent but never arrives | check Trash and Junk; ask the recipient to check spam |
| Certificate warning | expected only on a local test server; report it otherwise |
| "Mailbox full" | delete large messages and empty Trash, or ask for more quota |

Locked out after several wrong passwords? The server rate-limits sign-in
attempts. Wait an hour, or ask your administrator.
