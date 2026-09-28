# Personal n8n on a VPS

This runs one n8n instance with SQLite on a named Docker volume. The editor is protected by n8n's owner account. Docker publishes port 5678 on `127.0.0.1` only; your existing HTTPS reverse proxy serves the public subdomain and webhooks.

## First boot

1. On the VPS, install Docker Engine and the Compose plugin, and copy this `n8n/` directory there. Run commands below from that directory.
2. Copy `.env.example` to `.env`. Set `N8N_HOST` to the real HTTPS subdomain and set your timezone. Generate and set a unique encryption key:

   ```bash
   cp .env.example .env
   key="$(openssl rand -hex 32)"
   sed -i "s/^N8N_ENCRYPTION_KEY=.*/N8N_ENCRYPTION_KEY=$key/" .env
   unset key
   chmod 600 .env
   ```

   **Back up `N8N_ENCRYPTION_KEY` separately from the VPS and the nightly backups. If you lose this key, every stored credential becomes undecryptable and must be recreated.** Keep the key unchanged through updates and restores. Never commit `.env` or put the key in workflow JSON.

3. Configure the existing reverse proxy to forward `https://<your-n8n-subdomain>/` to `http://127.0.0.1:5678`. Preserve the original `Host` and send `X-Forwarded-Host`, `X-Forwarded-For`, and `X-Forwarded-Proto: https`. For Nginx, the relevant location is:

   ```nginx
   location / {
       proxy_pass http://127.0.0.1:5678;
       proxy_set_header Host $host;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-Host $host;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto https;
       proxy_http_version 1.1;
       proxy_set_header Upgrade $http_upgrade;
       proxy_set_header Connection "upgrade";
   }
   ```

   Make sure DNS points to the VPS and the proxy already has a valid TLS certificate. `WEBHOOK_URL` and `N8N_EDITOR_BASE_URL` are derived from `N8N_HOST`. `N8N_PROXY_HOPS=1` assumes exactly one trusted proxy in front of n8n; adjust if your actual proxy chain differs. Keep 5678 closed in the VPS firewall; only the reverse proxy should reach its loopback listener.

4. Start n8n and create the owner account at your HTTPS URL:

   ```bash
   docker compose config --quiet
   docker compose up -d
   curl --fail http://127.0.0.1:5678/healthz
   ```

   Open the HTTPS subdomain and complete n8n's first-boot owner setup. Use a strong password and enable two-factor authentication in n8n if available. Do not put another basic-auth gate in front of webhooks unless your senders can supply it.

## Starter workflow smoke tests

After the owner account exists, import both JSON files with `scripts/import-starters.sh` (or use **Import from file** in the editor). The workflows remain unpublished until you configure and publish them.

- **RSS to email digest:** Open `Starter: RSS to email digest`. Change the feed URL, sender, and recipient. Create/select an SMTP credential on **Email digest**. Run it manually and confirm the message arrives, then publish it for the daily schedule. The included NASA feed is only a sample.
- **Webhook to Telegram alert:** Open `Starter: Webhook to Telegram alert`. Create a Telegram bot credential, set its chat ID, and create a **Header Auth** credential on **Receive alert** with your own secret header name and value. Use n8n's test webhook URL while testing in the editor; send a JSON POST with that header and confirm the Telegram message. Publish the workflow, then send to `https://<your-n8n-subdomain>/webhook/personal-alert`. Keep the header value private. The owner login guards the editor; the webhook uses its own header credential.

For example, after publishing, send a test alert with your chosen header:

```bash
curl -X POST "https://<your-n8n-subdomain>/webhook/personal-alert" \
  -H 'Content-Type: application/json' -H 'X-Alert-Token: YOUR_SECRET' \
  -d '{"message":"n8n smoke test"}'
```

## Nightly backups

Run `scripts/backup.sh` nightly from the VPS account that can access Docker. It exports workflows and encrypted credentials with the n8n CLI, stops n8n briefly, copies the complete `/home/node/.n8n` volume to `backups/YYYY-MM-DD/run-HHMMSS-PID/data/`, and restarts n8n. It retains the current UTC date plus 13 previous dates. Each run also has `workflows.json` and `credentials.json`. Credentials remain encrypted; the separate encryption key is essential for recovery. Backups contain sensitive account data and should be copied to protected storage off the VPS.

Use a root-owned cron entry or a dedicated Docker-capable service account. Example for 02:15 UTC (use the absolute path on your VPS):

```cron
15 2 * * * /srv/n8n/scripts/backup.sh >>/var/log/n8n-backup.log 2>&1
```

The script uses a lock to avoid overlapping backups. Check the log and the dated directory after the first scheduled run. The copy pauses n8n, so plan for a short webhook outage during the backup.

### Restore drill

Practice on a separate disposable VPS or Docker host with the **same** `N8N_ENCRYPTION_KEY`. Never test a restore over production. Copy a dated backup directory and the separately stored key to that host. Put a matching `.env` beside `compose.yaml`, set a test hostname, and stop its n8n container. Replace only the test host's volume from the backed-up `data/` directory; for example:

```bash
docker compose down
docker volume create n8n-personal_n8n_data
docker run --rm -v n8n-personal_n8n_data:/data -v /path/to/backup/data:/restore:ro \
  alpine:3.21 sh -c 'rm -rf /data/* /data/.[!.]* /data/..?*; cp -a /restore/. /data/; chown -R 1000:1000 /data'
docker compose up -d
```

Confirm the owner can sign in, both workflows appear, and an existing credential works in a manual test. Keep the test webhook unpublished or isolated to avoid duplicate production actions. The volume copy is the complete restore; the CLI exports are extra recovery and inspection material. Restoring into an older n8n version after a schema migration may fail, so use the backup's pinned version or a compatible newer one.

## Updates

Read the [n8n release notes](https://github.com/n8n-io/n8n/releases) and choose an explicit stable version tag. Run:

```bash
scripts/update.sh 2.40.7
```

The script takes a fresh backup first, pulls the selected image, writes its tag to `.env`, restarts the service, and checks `/healthz`. It never follows `latest`. If health fails, inspect `docker compose logs n8n`; use the fresh backup for recovery if needed. Do not blindly downgrade across database migrations. Run the RSS and webhook smoke tests after each update and check the next nightly backup.

This is a single-person installation. Team management, workers, and high-availability scaling are outside its scope.

Reference: [n8n Docker installation](https://docs.n8n.io/hosting/installation/docker/), [reverse proxy webhook URLs](https://docs.n8n.io/hosting/configuration/configuration-examples/webhook-url/), and [CLI export/import](https://docs.n8n.io/hosting/cli-commands/).
