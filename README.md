# Atria server

The sync API for the desktop and mobile apps: **identity, tenancy, health and
sessions**, running on our own Indian VPS behind host nginx.

This directory is mirrored to the `ApexSync` repository, which is what the VPS
deploys from. Reasoning for the design lives in the main Atria repository, under
`audit/` — copies are kept in `docs/` in the ApexSync repository:

- `audit/06-sync-options.md` — the engine options that were evaluated and
  rejected, and why the schema work comes first.
- `audit/07-self-hosted-india-vps.md` — why a self-hosted VPS, sizing, backups,
  and what the terms of service can honestly claim about where data lives.

---

## 1. What this is, and what it deliberately is not

**Is:** a Postgres database and one small Dart API container, fronted by host
nginx at `https://api.apexbooks.in`. Sign-up, sign-in, device-scoped refresh
tokens, firm (tenant) creation, **firm erasure**, and row-level security so one
firm's books can never be read by another's account.

**Is not, yet:** the sync engine. No invoice, payment or stock table exists in
Postgres, because *which* of those columns are client-owned, server-owned, or
derived-and-never-synced is still an open decision (audit/06 §4.1, §5 step 1).
Guessing it would bake the wrong answer into a migration that devices have
already applied. What exists now is everything the sync engine will need to sit
on top of: identity, tenancy, RLS, client-minted UUIDs, and a migration runner.

---

## 2. Layout

```
server/
  docker-compose.yml          Postgres + API (+ migrate, behind a profile)
  .env.example                every setting, and which ones are secrets
  db/
    bootstrap.sql             extensions + the application role
    init/01-init.sh           first-boot hook (empty data directory only)
    apply-migrations.sh       the runner; used at boot and afterwards
    migrations/0001_identity.sql
    migrations/0002_firm_purges.sql
  api/                        Dart (shelf) service
    bin/atria_api.dart        entrypoint
    lib/src/
      config.dart             fail-fast environment parsing
      database.dart           pool, readiness, RLS-scoped transaction helper
      errors.dart             the only error type safe to show a client
      log.dart                one JSON object per line
      auth/                   JWT issuance, opaque refresh tokens, credentials
      http/                   JSON helpers + middleware (id, log, errors, auth)
      routes/                 health, auth, tenancy
    test/                     51 tests, no database required
  deploy/
    nginx/                    vhosts, rate-limit zones, proxy snippet
    tls/issue-cert.sh         the certificate bootstrap
  scripts/smoke-test.py       post-deploy end-to-end verification
```

---

## 3. Prerequisites

- A VPS with a static IPv4 address. Minimum 2 vCPU / 4 GB for a pilot;
  4 vCPU / 8 GB / 160 GB NVMe is the recommended size.
- Ubuntu 24.04 LTS (or similar), with `nginx`, `docker`, the compose plugin,
  and `certbot`.
- DNS: an **A record for `api.apexbooks.in`** pointing at the VPS. Also claim
  **`sync.apexbooks.in`** now, even though nothing listens on it — PowerSync
  requires its own dedicated subdomain later (`deploy/nginx/sites-available/
  sync.apexbooks.in.reserved`).

```sh
apt-get update
apt-get install -y nginx certbot docker.io docker-compose-v2
```

---

## 4. First deploy

```sh
# 1. Get the code and the environment.
cd /opt && git clone <repo> atria && cd atria/server
cp .env.example .env

# 2. Generate the two secrets. Do not type them by hand.
openssl rand -base64 48   # -> POSTGRES_SUPERUSER_PASSWORD
openssl rand -base64 48   # -> ATRIA_DB_PASSWORD
openssl rand -base64 48   # -> ATRIA_JWT_SECRET
$EDITOR .env

# 3. nginx rate-limit zones and the shared proxy snippet. Restart, because
#    conf.d is read at nginx start.
cp deploy/nginx/conf.d/atria-limits.conf /etc/nginx/conf.d/
cp deploy/nginx/snippets/atria-proxy.conf /etc/nginx/snippets/
nginx -t && systemctl restart nginx

# 4. Start Postgres and the API. On an empty volume, bootstrap.sql runs and then
#    every migration is applied.
docker compose up -d --build

# 5. Certificate, then enable the vhost. Run this BEFORE symlinking the site
#    file: nginx will not start if its ssl_certificate points at a file that
#    does not exist yet, and a server that will not start cannot serve the
#    challenge that would create it.
bash deploy/tls/issue-cert.sh api.apexbooks.in you@apexbooks.in

# 6. Prove it works.
python3 scripts/smoke-test.py --base-url https://api.apexbooks.in
```

Step 6 should print `passed 49   failed 0`. If it does not, §8 below is the
list of things that actually went wrong while building this.

> **Deploying onto an existing database.** The runner above applies every
> migration on first boot, but only on an *empty* volume. The live VPS was
> created at `0001`, so after pulling a version that adds a migration, apply it
> explicitly — `docker compose --profile tools run --rm migrate` — before the
> new code serves traffic. The API probes for every table it needs at `/ready`,
> so forgetting shows up as `schema_missing` rather than as a 500 mid-request.

---

## 5. Verifying by hand

```sh
curl -fsS https://api.apexbooks.in/health
# {"status":"ok","version":"0.1.0","uptimeSeconds":42}

curl -fsS https://api.apexbooks.in/ready
# {"status":"ready","checks":{"database":"ok"}}
```

`/health` never touches the database, so a database outage cannot make Docker
restart a healthy API container. `/ready` does, **and checks that the schema
exists** — `{"checks":{"database":"schema_missing"}}` means "run the migrations",
which is a different problem from `unreachable`.

The full flow:

```sh
BASE=https://api.apexbooks.in
EMAIL=owner@yourfirm.in

# Sign up. deviceId is a stable per-install id the app generates (UUID v7).
SIGNUP=$(curl -fsS -X POST $BASE/v1/auth/signup -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"a-real-password\",\"deviceId\":\"desktop-1\",\"platform\":\"windows\"}")

TOKEN=$(echo "$SIGNUP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["accessToken"])')

# Who am I, and which firms can I see? (empty until a firm exists)
curl -fsS $BASE/v1/me -H "authorization: Bearer $TOKEN"

# Create the firm. The id is minted by the client.
curl -fsS -X POST $BASE/v1/firms -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"firmId":"018f2a3b-4c5d-7e8f-9a0b-1c2d3e4f5a6b","name":"Active IT Solutions","gstin":"27ABCDE1234F1Z5"}'

# Erase it again. A real DELETE, not a flag — DPDP Rule 8 needs erasure to
# erase, and a tombstone is not an erasure. 404 means there is nothing left
# there, which is the state the caller asked for.
curl -fsS -X DELETE $BASE/v1/firms/018f2a3b-4c5d-7e8f-9a0b-1c2d3e4f5a6b \
  -H "authorization: Bearer $TOKEN"
# {"firmId":"018f2a3b-...","erased":true}
```

The erase is administrative, and a 404 covers "no such firm", "not your firm"
and "you are not an admin of it" deliberately — distinguishing them would turn
the endpoint into a way to probe other tenants' firm ids. The id is recorded in
`app_firm_purges`, so a device that was offline when the deletion happened gets
a 409 on its next push instead of quietly undoing it.

---

## 6. Day-2 operations

| Task | Command |
|---|---|
| Apply new migrations | `docker compose --profile tools run --rm migrate` |
| Is it healthy? | `docker compose ps`, `curl -fsS localhost:8080/ready` |
| Logs (last 100 lines) | `docker compose logs --tail=100 api` |
| Logs, filtered to errors | `docker compose logs api \| grep -a '"level":"error"'` |
| Follow logs | `docker compose logs -f api db` |
| Restart the API | `docker compose restart api` |
| Deploy a new version | `git pull && docker compose up -d --build && docker compose --profile tools run --rm migrate` |
| Stop everything (keep data) | `docker compose down` |
| **Destroy everything incl. the database** | `docker compose down -v` — never on the server by accident |
| Database shell | `docker compose exec db psql -U atria_superuser -d atria` |
| Certificate status | `certbot certificates`, `systemctl list-timers certbot.timer` |

**A new migration does not run by itself on an existing volume.**
`db/init/01-init.sh` fires only when the Postgres data directory is empty, which
is once, ever. After that, migrations run when you run the `migrate` profile.
The runner is idempotent — it records each applied file in `schema_migrations`
and prints `skip` for the rest — so it is safe to run on every deploy.

**Backups are not set up here.** Postgres is the only irreplaceable state in this
stack, and a nightly encrypted dump to a second Indian location — with a restore
you have actually performed — is the next piece of work. See audit/07 §8.

---

## 7. Local development

```sh
cd server
cp .env.example .env
# Change API_HOST_PORT if 8080 is taken on your machine.
docker compose up -d --build
python3 scripts/smoke-test.py --base-url http://127.0.0.1:8080
```

Postgres is never published on the host, so there is no port to forget to close.
To poke at the database:

```sh
docker compose exec db psql -U atria_superuser -d atria
```

The API's own tests need no database and no Docker:

```sh
cd server/api
dart pub get
dart analyze
dart test          # 51 tests
```

---

## 8. Troubleshooting — what actually went wrong

| Symptom | Cause | Fix |
|---|---|---|
| `/ready` → `{"database":"schema_missing"}` | Migrations have not run on this volume | `docker compose --profile tools run --rm migrate` |
| `atria-init` never mentions the new migration | `docker-entrypoint-initdb.d` only runs on an **empty** data directory | Use the `migrate` profile. Do not `down -v` on a server with real data to "fix" this. |
| `501 Not Implemented` / `502 Bad Gateway` from nginx | The API container is not up, or `API_HOST_PORT` in `.env` does not match `proxy_pass` in the vhost | `docker compose ps`, then `curl localhost:8080/health` |
| nginx fails `nginx -t` with `cannot load certificate` | The vhost was enabled before the certificate existed | Run `deploy/tls/issue-cert.sh`; it sequences this correctly |
| `429 Too Many Requests` from `/v1/auth/*` | The nginx auth zone is 10 requests/minute per IP | Expected. Wait, or raise `rate=` in `atria-limits.conf` |
| The API refuses to start, exit code 78 | A missing or too-short `ATRIA_JWT_SECRET`, or any missing `ATRIA_DB_*` | It prints every problem at once; fix them all and restart |
| Postgres log: `FATAL: password authentication failed` | `ATRIA_DB_PASSWORD` was changed after the volume was created; the role still has the old password | Re-run the bootstrap against the live database, or recreate the volume if the data is disposable |
| `psql: error: connection to server on socket ... failed` during init | The Postgres image does not export libpq variables, and starts socket-only during init | Already handled in `init/01-init.sh` |

---

## 9. Security posture

In place:

- **No public database.** Postgres has no `ports:` mapping; the API is published
  on `127.0.0.1` only. Host nginx is the sole public listener.
- **TLS with HSTS**, TLS 1.2+, OCSP stapling, and a renewal hook that actually
  reloads nginx (a renewed certificate that nginx has not re-read is not a
  renewed certificate).
- **Rate limiting** on `/v1/auth/*` (10/min/IP) and on everything else
  (120/min/IP).
- **Passwords and refresh tokens are hashed by Postgres** (`pgcrypto`), so no
  plaintext reaches a table, a query log, or a `pg_dump`, and we ship no
  password-hashing code of our own.
- **Refresh tokens are opaque, single-use and device-scoped.** Rotation is a
  conditional `UPDATE ... RETURNING`, so two simultaneous refreshes cannot both
  win. A lost phone is revocable on its own.
- **The application role owns no tables** and is not a superuser, so the
  row-level security policies actually apply to it. Permissions are explicit
  grants; the test suite asserts both properties.
- **Row-level security** on the tenant tables, keyed on a transaction-local
  `app.user_id`. `set_config(..., true)` means the identity cannot leak to
  whichever request reuses the pooled connection. Unset means deny, not allow.
- **Firm creation goes through one `SECURITY DEFINER` procedure** which binds the
  action to the authenticated identity, because a brand-new firm has no members
  and no membership policy could authorise its own creation.
- **A real erasure path per firm.** `DELETE /v1/firms/{id}` is a genuine
  `DELETE` — not a tombstone — authorised by the `firms_delete_admin` policy, so
  a member who is not an admin is refused (and answered with the same 404 as a
  stranger). The erasure and its ledger entry commit together, and the ledger
  holds the firm id, the account and the timestamp — no name, no GSTIN, no
  customer, no books. It exists so a device that was offline when the deletion
  happened cannot push the firm back, and so "we deleted it on <date>" is
  answerable. **Erasing a firm on the server is not yet reachable from a
  backup**: a restore can re-create it locally, and the push is then refused.
- **No internals in error responses.** Anything that is not an `ApiException`
  becomes a generic 500; the stack trace is logged, never returned. A test
  asserts a connection string containing a password cannot reach the client.
- **Non-root container, read-only root filesystem, `no-new-privileges`.**
- **Fail-fast configuration** at boot, so a missing secret is a startup failure
  rather than a silently weakened runtime.

Still to do (audit/07 §9):

- SSH hardening, `unattended-upgrades`, and host firewalling.
- Backups and a tested restore.
- Alerting on disk > 80%, certificate expiry, and API 5xx rate.
- **Propagating** an erasure into backups, once backups exist. Rule 8 wants
  deletion to reach the copies too, on a stated timeline; `app_firm_purges`
  covers the live database and the stale-device case, not a nightly dump.
- Versioned consent capture and a named grievance contact, before the terms of
  service mention "data stored in India".

**Log retention.** Request logs include the client IP, which is personal data.
`docker-compose.yml` caps each container's logs at 10 MB × 5 files, so the
retention window is bounded by traffic rather than by policy. Decide the policy
before launch and write it down.

---

## 10. Not built yet

Listed so nobody discovers it the hard way:

1. **The sync engine** — push from `sync_queue`, pull by watermark, conflict
   detection. See audit/06 §5.
2. **Password reset and email verification.** There is no mail path at all yet.
   Whichever provider is chosen becomes a sub-processor in the terms of service.
3. **Revoking a session by device** (`DELETE /v1/devices/{id}`). The data model
   supports it; the route does not exist.
4. **Timing equalisation on login.** The response is identical for "no such
   account" and "wrong password", but the response *time* is not equalised
   against a dummy hash.
5. **Refresh-token family reuse detection.** A replayed rotated token is
   rejected, but the whole family is not revoked, which is what you want if the
   token was stolen.
6. **Realtime liveness.** At this scale a foreground pull finishes the job.
7. **Nothing in the app is signed in yet**, so no device calls any of this —
   `POST /v1/firms` and `DELETE /v1/firms/{id}` are reached only by
   `scripts/smoke-test.py`. The app half is built and gated: Settings → Atria
   server knows its address and its device id, and "Remove this business"
   offers the server erasure but disables it until there is a session to send.
   Until sign-in exists, the API is verified by the smoke test rather than by a
   real client.
