#!/usr/bin/env python3
"""Verification of the mail stack's SMTP and API surface.

Local test stack:  python3 scripts/smoke-test.py
Against the VPS:   MAIL_HOST=mail.example.com SUBMISSION_PORT=587 SUBMISSIONS_PORT=465 \
                   SENDER=info@a.com PASSWORD=... RCPT=abc@b.com VERIFY_TLS=1 \
                   API_BASE=https://mail.example.com python3 scripts/smoke-test.py

The API token is read from mailu.env when API_TOKEN is not exported. Without a
token the negative checks still run; only the positive one is skipped.

NOTE ON OPEN-RELAY TESTING
  This script cannot prove the server is not an open relay. Postfix trusts
  `mynetworks` (127.0.0.1/32 plus the Mailu docker SUBNET), and Docker's
  userland proxy rewrites the source address of loopback connections to the
  bridge gateway, which falls inside that subnet. A port-25 test run from the
  Docker host therefore always looks "accepted" - locally and on the VPS alike.
  The definitive test must originate OFF the host. See docs/DEPLOY.md, section
  "Open-relay test".
"""
import os
import pathlib
import smtplib
import ssl
import sys
import urllib.error
import urllib.request
from email.message import EmailMessage

HOST = os.getenv("MAIL_HOST", "127.0.0.1")
SUBMISSION = int(os.getenv("SUBMISSION_PORT", "5587"))
SUBMISSIONS = int(os.getenv("SUBMISSIONS_PORT", "4465"))
SENDER = os.getenv("SENDER", "info@a.test")
PASSWORD = os.getenv("PASSWORD", "Passw0rd!23")
RCPT = os.getenv("RCPT", "abc@b.test")
API_BASE = os.getenv("API_BASE", "https://127.0.0.1:8443").rstrip("/")


def _api_token():
    token = os.getenv("API_TOKEN")
    if token:
        return token
    env = pathlib.Path(__file__).resolve().parent.parent / "mailu.env"
    if env.is_file():
        for line in env.read_text().splitlines():
            if line.startswith("API_TOKEN="):
                return line.split("=", 1)[1].strip()
    return None


API_TOKEN = _api_token()

ctx = ssl.create_default_context()
if os.getenv("VERIFY_TLS", "0") != "1":
    # The local stack uses a self-signed certificate.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE


def _message(subject):
    msg = EmailMessage()
    msg["From"], msg["To"], msg["Subject"] = SENDER, RCPT, subject
    msg.set_content(f"Body for: {subject}")
    return msg


def _connect(port, implicit):
    if implicit:
        return smtplib.SMTP_SSL(HOST, port, context=ctx, timeout=20)
    s = smtplib.SMTP(HOST, port, timeout=20)
    s.starttls(context=ctx)
    return s


def send_starttls_587():
    with _connect(SUBMISSION, implicit=False) as s:
        s.login(SENDER, PASSWORD)
        s.send_message(_message("port 587 STARTTLS authenticated"))


def send_implicit_465():
    with _connect(SUBMISSIONS, implicit=True) as s:
        s.login(SENDER, PASSWORD)
        s.send_message(_message("port 465 implicit TLS authenticated"))


def _requires_auth(port, implicit):
    with _connect(port, implicit) as s:
        try:
            s.sendmail("attacker@evil.test", "victim@gmail.com", "Subject: relay\n\nx")
        except smtplib.SMTPSenderRefused as exc:
            if exc.smtp_code == 530:
                return
            raise
        raise AssertionError(f"port {port} accepted unauthenticated relay")


def submission_587_requires_auth():
    _requires_auth(SUBMISSION, implicit=False)


def submission_465_requires_auth():
    _requires_auth(SUBMISSIONS, implicit=True)


def _api(path, token="", method="GET", body=None):
    """HTTP status for an API call, treating error responses as data."""
    req = urllib.request.Request(f"{API_BASE}/api/v1{path}", method=method)
    if token:
        req.add_header("Authorization", token)
    if body is not None:
        req.add_header("Content-Type", "application/json")
        req.data = body.encode()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code


def api_without_token_is_401():
    code = _api("/domain")
    assert code == 401, f"expected 401 without a token, got {code}"


def api_with_bad_token_is_403():
    code = _api("/domain", token="deadbeef" * 8)
    assert code == 403, f"expected 403 for an invalid token, got {code}"


def api_bad_token_cannot_create_user():
    victim = "smoketest-intruder@a.test"
    code = _api(
        "/user",
        token="deadbeef" * 8,
        method="POST",
        body='{"email": "%s", "raw_password": "irrelevant"}' % victim,
    )
    assert code in (401, 403), f"unauthenticated write returned {code}"
    if API_TOKEN:
        assert _api(f"/user/{victim}", token=API_TOKEN) == 404, \
            f"{victim} was created despite the rejected request"


def api_with_valid_token_is_200():
    if not API_TOKEN:
        raise RuntimeError("no API_TOKEN available (export it or add it to mailu.env)")
    code = _api("/domain", token=API_TOKEN)
    assert code == 200, f"expected 200 with a valid token, got {code}"


CHECKS = (
    send_starttls_587,
    send_implicit_465,
    submission_587_requires_auth,
    submission_465_requires_auth,
    api_without_token_is_401,
    api_with_bad_token_is_403,
    api_bad_token_cannot_create_user,
    api_with_valid_token_is_200,
)

if __name__ == "__main__":
    failures = 0
    for check in CHECKS:
        try:
            check()
            print(f"PASS  {check.__name__}")
        except Exception as exc:
            failures += 1
            print(f"FAIL  {check.__name__}: {type(exc).__name__}: {exc}")
    print("\nReminder: open-relay must be verified from an off-host machine")
    print("(docs/DEPLOY.md, section 'Open-relay test').")
    sys.exit(1 if failures else 0)
