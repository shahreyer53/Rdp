#!/usr/bin/env bash
set -Eeuo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
container_id="$(docker compose ps -q n8n)"
[[ -n "$container_id" ]] || { echo 'Start n8n and create the owner account first' >&2; exit 1; }

for workflow in rss-email-digest webhook-telegram-alert; do
  docker cp "$project_dir/workflows/$workflow.json" "$container_id:/tmp/$workflow.json"
  docker exec "$container_id" n8n import:workflow --input="/tmp/$workflow.json"
done
echo 'Imported both starter workflows. Configure credentials and addresses in the editor before publishing.'
