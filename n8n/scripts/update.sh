#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Usage: scripts/update.sh VERSION (for example, 2.40.7)' >&2
  exit 2
fi
version="$1"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
[[ -f .env ]] || { echo 'Missing .env' >&2; exit 1; }

"$project_dir/scripts/backup.sh"
docker pull "docker.n8n.io/n8nio/n8n:$version"

new_env="$(mktemp "$project_dir/.env.tmp.XXXXXX")"
trap 'rm -f -- "$new_env"' EXIT
awk -v version="$version" '
  /^N8N_VERSION=/ { print "N8N_VERSION=" version; found=1; next }
  { print }
  END { if (!found) print "N8N_VERSION=" version }
' .env > "$new_env"
chmod 600 "$new_env"
mv -- "$new_env" .env
trap - EXIT

docker compose up -d --no-deps --force-recreate n8n
for attempt in {1..30}; do
  if curl --fail --silent --show-error --max-time 2 http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
    echo "n8n $version is healthy"
    exit 0
  fi
  sleep 2
done
echo 'n8n did not become healthy. Check docker compose logs n8n and restore from the new backup if necessary.' >&2
exit 1
