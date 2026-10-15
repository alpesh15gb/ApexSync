# Deploy bill scanning with PDF pages and APEXV1

The updated Windows app sends original PDFs through `documentBase64`.
The API sniffs the PDF header and forwards a Chat Completions `file` part
with filename `bill.pdf` and a base64 PDF data URI to the existing APEXV1
combo. It does not rasterize the PDF locally. Original documents are limited
to 10 MB. The previous single-image and ordered multi-image contracts remain
supported for photos and older clients.

Native PDF handling depends on the selected provider's file-input support.
A live PDF scan through the deployed combo is still required to verify
compatibility and latency; native upload does not guarantee a 5–10 second scan.
The prompt asks the model to read every PDF page, preserve the printed total,
and warn about arithmetic mismatches, missing pages or proforma invoices.
The gateway's missing Playwright runtime is a separate provider problem.
This update reports that failure clearly and avoids a pointless retry.
It does not install browsers or modify OmniRoute's combos. Keep the existing
`APEXV1` combo and select it through the API environment.

## API deployment on the current server

```bash
cd /opt/atria-server
git status --short
git pull --ff-only origin main
cp -p .env ".env.backup-$(date +%Y%m%d-%H%M%S)"
if grep -q '^ATRIA_SCAN_MODEL=' .env; then
  sed -i 's/^ATRIA_SCAN_MODEL=.*/ATRIA_SCAN_MODEL=APEXV1/' .env
else
  printf '\nATRIA_SCAN_MODEL=APEXV1\n' >> .env
fi
docker compose build api
docker compose up -d --no-deps --force-recreate api
docker exec atria-server-api-1 printenv ATRIA_SCAN_MODEL
curl -fsS http://127.0.0.1:8090/health
```

Stop if the pull or build fails. If tracked files have local edits, inspect
and preserve them before pulling. Never overwrite `.env` with `.env.example`.
The printed scan model must be `APEXV1`. No database migration is needed.

## nginx: current deployment

The deployed host uses `/etc/nginx/sites-enabled/apexbooks-api`, port 8090,
and Certbot-managed TLS. Do not replace that file with the repository's
generic example, which uses port 8080. Resolve and back up its real path:

```bash
scan_nginx_config=$(readlink -f /etc/nginx/sites-enabled/apexbooks-api)
sudo cp -p "$scan_nginx_config" "$scan_nginx_config.backup-$(date +%Y%m%d-%H%M%S)"
sudo nano "$scan_nginx_config"
```

Inside the HTTPS `server` block for `api.apexbooks.in`, add this location
alongside the existing `location /`. Add it only once:

```nginx
location ~ ^/v1/firms/[^/]+/scan-bill$ {
    client_max_body_size 15m;
    proxy_pass http://127.0.0.1:8090;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 255s;
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

The 15 MB allowance covers base64 expansion of the 10 MB image payload.
Each provider attempt is bounded to 120 seconds, so the proxy allows both
attempts. The updated app waits 270 seconds.

## Verification

Install the updated Windows app. Test a photo, a single-page PDF and a
multi-page PDF through **Choose photo or PDF**. Check that all bill lines
and the final total appear correctly in review before saving. If it fails:

```bash
docker logs --since=5m atria-server-api-1 2>&1 | grep -E 'scan_|scan-bill'
docker logs --since=5m --tail=100 omniroute 2>&1
```

Local validation: 71 API tests, including multiple-page validation, ordered
provider payloads and missing-browser errors; 23 app tests. Live model image
support and native PDF handling still require the above end-to-end checks.
