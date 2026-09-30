#!/usr/bin/env python3
"""End-to-end check that a deployed Atria API actually works.

Run it after a deploy, and after any change to the auth path. It exercises the
real HTTP surface against a real database and a real row-level-security policy
set — the things unit tests cannot reach.

    # against a local stack
    python server/scripts/smoke-test.py

    # against the server (from anywhere with curl-equivalent access)
    python server/scripts/smoke-test.py --base-url https://api.apexbooks.in

    # only the HTTP surface, no database introspection
    python server/scripts/smoke-test.py --no-db-checks

It creates two accounts and two firms with random-ish names, erases one of them,
and leaves the rest behind — so it is safe to run against production, but it does
accumulate rows, and it will be blocked by the nginx rate limit on /v1/auth/ if
you run it more than about ten times a minute.

Exit code is 0 only if every check passed.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid

PASSWORD = "smoke-test-password"


class Checker:
    def __init__(self) -> None:
        self.passed = 0
        self.failed: list[str] = []

    def check(self, name: str, ok: bool, detail: object = "") -> bool:
        if ok:
            self.passed += 1
            print(f"  PASS  {name}")
        else:
            self.failed.append(name)
            suffix = f"  <- {detail}" if detail != "" else ""
            print(f"  FAIL  {name}{suffix}")
        return ok


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument(
        "--no-db-checks",
        action="store_true",
        help="skip the row-level-security checks that need psql in the db container",
    )
    parser.add_argument(
        "--db-service",
        default="db",
        help="compose service name for Postgres, used by the RLS checks",
    )
    args = parser.parse_args()

    base = args.base_url.rstrip("/")
    c = Checker()
    run_id = uuid.uuid4().hex[:8]

    def call(method, path, body=None, token=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(base + path, data=data, method=method)
        if data:
            request.add_header("content-type", "application/json")
        if token:
            request.add_header("authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                raw = response.read().decode()
                return response.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read().decode()
            try:
                return error.code, (json.loads(raw) if raw else None)
            except json.JSONDecodeError:
                return error.code, raw

    print(f"== unauthenticated surface ({base})")
    status, body = call("GET", "/health")
    c.check("health needs no auth and reports ok", status == 200 and body["status"] == "ok", (status, body))
    status, body = call("GET", "/ready")
    c.check("ready reports the schema is present", status == 200 and body["checks"]["database"] == "ok", (status, body))
    status, body = call("GET", "/nonexistent")
    c.check("an unknown path is a JSON 404", status == 404 and body["error"]["code"] == "not_found", (status, body))
    status, body = call("GET", "/v1/me")
    c.check("a protected route without a token is a JSON 401", status == 401 and body["error"]["code"] == "unauthorized", (status, body))
    status, body = call("POST", "/v1/auth/login", {"email": "x"})
    c.check("a missing field is a 400 that names it", status == 400 and "password" in body["error"]["message"], (status, body))

    print("== identity")
    email_one = f"smoke-{run_id}-one@example.com"
    email_two = f"smoke-{run_id}-two@example.com"
    status, body = call("POST", "/v1/auth/signup", {"email": email_one.upper(), "password": PASSWORD, "deviceId": "smoke-desktop", "platform": "windows"})
    if not c.check("signup returns 201", status == 201, (status, body)):
        print("\nCannot continue without a signed-up account.", file=sys.stderr)
        return 1
    user_one, token_one = body["user"]["id"], body["accessToken"]
    c.check("the email is normalised to lowercase", body["user"]["email"] == email_one, body["user"]["email"])
    c.check("a 15-minute access token is issued", body["expiresIn"] == 900 and body["refreshToken"], body)

    status, body = call("POST", "/v1/auth/signup", {"email": email_one, "password": PASSWORD, "deviceId": "smoke-desktop"})
    c.check("signing up twice is a 409, not a 500", status == 409, (status, body))

    status, body = call("GET", "/v1/me", token=token_one)
    c.check("a new account has no firms", status == 200 and body["firms"] == [], (status, body))
    c.check("the access token carries the device", body.get("deviceId") == "smoke-desktop", body)

    print("== tenancy")
    firm_id = str(uuid.uuid4())
    status, body = call("POST", "/v1/firms", {"firmId": firm_id, "name": f"Smoke Firm {run_id}", "gstin": "27ABCDE1234F1Z5"}, token=token_one)
    c.check("firm creation returns 201", status == 201, (status, body))
    status, body = call("POST", "/v1/firms", {"firmId": firm_id, "name": "Duplicate"}, token=token_one)
    c.check("re-creating the same firm is a 409, not a 500", status == 409, (status, body))
    status, body = call("POST", "/v1/firms", {"firmId": "not-a-uuid", "name": "Bad"}, token=token_one)
    c.check("a malformed firm id is a 400 before it reaches Postgres", status == 400, (status, body))
    status, body = call("GET", "/v1/me", token=token_one)
    c.check("the creator is an admin of the firm", status == 200 and len(body["firms"]) == 1 and body["firms"][0]["role"] == "admin", (status, body))

    status, body = call("POST", "/v1/auth/signup", {"email": email_two, "password": PASSWORD, "deviceId": "smoke-phone", "platform": "android"})
    c.check("a second account can sign up", status == 201, (status, body))
    user_two, token_two = body["user"]["id"], body["accessToken"]
    status, body = call("GET", "/v1/me", token=token_two)
    c.check("the second account sees none of the first account's firms", status == 200 and body["firms"] == [], (status, body))

    print("== erasure")
    # A second firm is kept, so "the business was erased" is distinguishable
    # from "the account was wiped down to nothing".
    keep_id = str(uuid.uuid4())
    status, body = call("POST", "/v1/firms", {"firmId": keep_id, "name": f"Keep Firm {run_id}"}, token=token_one)
    c.check("a second firm is created, to prove the erase is scoped", status == 201, (status, body))

    status, _ = call("DELETE", f"/v1/firms/{firm_id}")
    c.check("erasing without a token is a 401", status == 401, status)
    status, body = call("DELETE", f"/v1/firms/{firm_id}", token=token_two)
    c.check("another account gets a 404, not a 403 - no firm-existence oracle", status == 404 and body["error"]["code"] == "not_found", (status, body))
    status, body = call("DELETE", "/v1/firms/not-a-uuid", token=token_one)
    c.check("a malformed firm id is a 400 before it reaches Postgres", status == 400, (status, body))

    status, body = call("DELETE", f"/v1/firms/{firm_id}", token=token_one)
    c.check("the owner can erase the business", status == 200 and body["erased"] is True, (status, body))
    status, body = call("GET", "/v1/me", token=token_one)
    c.check("the erased firm is gone and the other one is untouched", status == 200 and [f["firmId"] for f in body["firms"]] == [keep_id], (status, body))
    status, body = call("DELETE", f"/v1/firms/{firm_id}", token=token_one)
    c.check("erasing it again is a 404, so a retry is safe", status == 404, (status, body))
    status, body = call("POST", "/v1/firms", {"firmId": firm_id, "name": f"Smoke Firm {run_id}"}, token=token_one)
    c.check("re-creating an erased id is a 409, so a stale device cannot undo the erase", status == 409, (status, body))

    print("== credentials")
    status, body = call("POST", "/v1/auth/login", {"email": email_one, "password": "wrong-password", "deviceId": "smoke-desktop"})
    c.check("a wrong password is 401", status == 401, (status, body))
    status, body = call("POST", "/v1/auth/login", {"email": f"nobody-{run_id}@example.com", "password": "wrong-password", "deviceId": "smoke-desktop"})
    c.check("an unknown account gives an identical 401 (no enumeration)", status == 401 and body["error"]["message"] == "Email or password is incorrect.", (status, body))
    status, body = call("GET", "/v1/me", token="garbage.token.here")
    c.check("a forged token is 401", status == 401, (status, body))

    print("== sessions")
    status, body = call("POST", "/v1/auth/login", {"email": email_one, "password": PASSWORD, "deviceId": "smoke-phone", "platform": "android"})
    c.check("the same account can sign in on a second device", status == 200, (status, body))
    refresh = body["refreshToken"]
    status, body = call("POST", "/v1/auth/refresh", {"refreshToken": refresh})
    c.check("refresh returns a different refresh token", status == 200 and body["refreshToken"] != refresh, (status, body))
    rotated = body["refreshToken"]
    status, _ = call("POST", "/v1/auth/refresh", {"refreshToken": refresh})
    c.check("the old refresh token cannot be replayed", status == 401, status)
    status, body = call("POST", "/v1/auth/refresh", {"refreshToken": rotated})
    c.check("the rotated token works", status == 200, (status, body))
    status, _ = call("POST", "/v1/auth/logout", {"refreshToken": body["refreshToken"]})
    c.check("logout succeeds", status == 200, status)
    status, _ = call("POST", "/v1/auth/refresh", {"refreshToken": rotated})
    c.check("a revoked token is rejected", status == 401, status)

    if not args.no_db_checks:
        print("== row-level security (direct database introspection)")

        def container_env(name: str) -> str:
            """Read a variable from the database container's own environment.

            Reading it from the container rather than hardcoding it means this
            script keeps working when POSTGRES_USER / POSTGRES_DB /
            ATRIA_DB_USER are changed in .env — otherwise the checks would fail
            to connect and quietly report SKIP, which is the worst outcome for
            a script whose entire job is to tell you the deployment is fine.
            """
            result = subprocess.run(
                ["docker", "compose", "exec", "-T", args.db_service,
                 "sh", "-c", f'printf %s "${name}"'],
                capture_output=True, text=True,
            )
            return result.stdout.strip()

        superuser = container_env("POSTGRES_USER")
        database = container_env("POSTGRES_DB")
        app_role = container_env("ATRIA_DB_USER")

        # Interpolated into SQL below, so refuse anything that is not a plain
        # identifier rather than escaping and hoping.
        identifier = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,62}$")
        bad = [n for n in (superuser, database, app_role) if not identifier.match(n or "")]
        if bad:
            print(f"  SKIP  database checks (unexpected role/database names: {bad})")
        else:
            def sql(statement: str):
                result = subprocess.run(
                    ["docker", "compose", "exec", "-T", args.db_service, "psql",
                     "-tA", "-U", superuser, "-d", database, "-c", statement],
                    capture_output=True, text=True,
                )
                if result.returncode != 0:
                    return None, (result.stderr or result.stdout).strip()
                return result.stdout.strip().splitlines()[-1] if result.stdout.strip() else "", None

            value, error = sql(f'SET ROLE "{app_role}"; SELECT count(*) FROM firms;')
            if value is None:
                print(f"  SKIP  database checks ({error})")
            else:
                c.check("with no identity set, the app role sees zero firms", value == "0", value)
                value, _ = sql(f'SET ROLE "{app_role}"; SELECT set_config(\'app.user_id\',\'{user_one}\',false); SELECT count(*) FROM firms;')
                c.check("the first account sees exactly its own firm", value == "1", value)
                value, _ = sql(f'SET ROLE "{app_role}"; SELECT set_config(\'app.user_id\',\'{user_two}\',false); SELECT count(*) FROM firms;')
                c.check("the second account sees zero of them", value == "0", value)
                value, _ = sql(f"SELECT rolsuper FROM pg_roles WHERE rolname = '{app_role}';")
                c.check("the app role is not a superuser", value == "f", value)
                value, _ = sql("SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relname='firms';")
                c.check("the app role does not own the tables (or RLS would be bypassed)", value != app_role, value)
                value, _ = sql(
                    "SELECT count(*) FROM pg_policies WHERE schemaname='public' AND policyname = ANY("
                    "ARRAY['firms_select_member','firms_update_admin','firms_delete_admin',"
                    "'firm_members_select_member','firm_members_write_admin',"
                    "'firm_changes_select_member','firm_changes_insert_member']);"
                )
                # By name, not a bare count: 0003 adds two policies and a
                # bare "5" broke the moment it first applied. A missing
                # policy still fails this; a new one added later does not.
                c.check("every tenant policy the migrations create exists (7 expected)", value == "7", value)
                value, _ = sql("SHOW wal_level;")
                c.check("wal_level is logical (reserved for PowerSync)", value == "logical", value)
                value, _ = sql("SELECT count(*) FROM schema_migrations;")
                c.check("at least one migration is recorded", value is not None and int(value) >= 1, value)

                # The erasure, checked in the database rather than through the
                # API: the API agreeing with itself proves nothing about
                # whether the row is actually gone.
                value, _ = sql(f"SELECT count(*) FROM firms WHERE id = '{firm_id}';")
                c.check("the erased firm row is really gone from Postgres", value == "0", value)
                value, _ = sql(f"SELECT count(*) FROM firm_members WHERE firm_id = '{firm_id}';")
                c.check("its memberships cascaded away with it", value == "0", value)
                value, _ = sql(f"SELECT count(*) FROM app_firm_purges WHERE firm_id = '{firm_id}';")
                c.check("the erasure is recorded in the ledger", value == "1", value)
                value, _ = sql("SELECT count(*) FROM information_schema.columns WHERE table_name = 'app_firm_purges';")
                c.check("and the ledger holds no firm data: three id/timestamp columns, nothing else", value == "3", value)

                # The authorization boundary itself, which only a direct
                # insert can reach: the API has no invite endpoint, so there is
                # no other way to build a member who is NOT an admin. Without
                # this the suite would only prove that *strangers* cannot
                # erase, never that a colleague with read access cannot.
                #
                # Last, because it deliberately leaves a second firm on the
                # account and the checks above count them.
                member_firm = str(uuid.uuid4())
                status, body = call("POST", "/v1/firms", {"firmId": member_firm, "name": f"Member Firm {run_id}"}, token=token_one)
                c.check("a firm is set up for the non-admin member check", status == 201, (status, body))
                # A failed insert leaves `value` as None and the two checks
                # below report SKIP rather than passing on a firm that was
                # never set up.
                value, error = sql(
                    "INSERT INTO firm_members (id, firm_id, name, role, user_id) "
                    f"VALUES (gen_random_uuid()::text, '{member_firm}', 'Staff', 'staff', '{user_two}');"
                )
                if value is None:
                    print(f"  SKIP  non-admin erase check ({error})")
                else:
                    status, body = call("DELETE", f"/v1/firms/{member_firm}", token=token_two)
                    c.check("a member who is not an admin cannot erase the business (404)", status == 404, (status, body))
                    status, body = call("GET", "/v1/me", token=token_one)
                    c.check("and the business survives for its admin", status == 200 and any(f["firmId"] == member_firm for f in body["firms"]), (status, body))
                    call("DELETE", f"/v1/firms/{member_firm}", token=token_one)

    print()
    print(f"passed {c.passed}   failed {len(c.failed)}")
    if c.failed:
        print("FAILED: " + "; ".join(c.failed))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
