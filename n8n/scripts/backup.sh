#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
backup_root="$project_dir/backups"
mkdir -p "$backup_root"
exec 9>"$backup_root/.backup.lock"
flock -n 9 || { echo 'Another backup is running' >&2; exit 1; }

day="$(date -u +%F)"
run="run-$(date -u +%H%M%S)-$$"
mkdir -p "$backup_root/$day"
staging="$(mktemp -d "$backup_root/$day/.partial.XXXXXX")"
container_tmp="/tmp/n8n-backup-${day}-$$"
stopped=0

cleanup() {
  result=$?
  if (( stopped )); then
    if ! docker compose up -d --no-deps n8n; then
      echo 'CRITICAL: n8n did not restart after backup; inspect docker compose logs n8n' >&2
      result=1
    fi
  fi
  if [[ -d "$staging" ]]; then rm -rf -- "$staging"; fi
  exit "$result"
}
trap cleanup EXIT

container_id="$(docker compose ps -q n8n)"
if [[ -z "$container_id" || "$(docker inspect -f '{{.State.Running}}' "$container_id")" != true ]]; then
  echo 'n8n must be running before backup' >&2
  exit 1
fi

docker exec "$container_id" mkdir -m 700 "$container_tmp"
export_or_empty() {
  local kind="$1" output="$2" result
  if result="$(docker exec "$container_id" "n8n" "export:$kind" --all --output="$output" 2>&1)"; then
    echo "$result"
  elif [[ "$result" == *"No $kind found with specified filters"* ]] ||
       [[ "$kind" == workflow && "$result" == *"No workflows found with specified filters"* ]] ||
       [[ "$kind" == credentials && "$result" == *"No credentials found with specified filters"* ]]; then
    docker exec "$container_id" sh -c 'printf "[]\n" > "$1"' sh "$output"
    echo "No $kind to export; saved an empty JSON array"
  else
    echo "$result" >&2
    return 1
  fi
}
export_or_empty workflow "$container_tmp/workflows.json"
export_or_empty credentials "$container_tmp/credentials.json"

stopped=1
docker compose stop n8n
docker cp "$container_id:$container_tmp/workflows.json" "$staging/workflows.json"
docker cp "$container_id:$container_tmp/credentials.json" "$staging/credentials.json"
mkdir "$staging/data"
docker cp "$container_id:/home/node/.n8n/." "$staging/data/"

docker compose up -d --no-deps n8n
stopped=0
mv -- "$staging" "$backup_root/$day/$run"
staging=''

# Keep the current UTC day and the previous 13 calendar days.
cutoff="$(date -u -d '13 days ago' +%F)"
for directory in "$backup_root"/20??-??-??; do
  [[ -d "$directory" ]] || continue
  [[ "${directory##*/}" < "$cutoff" ]] && rm -rf -- "$directory"
done
echo "Backup saved to $backup_root/$day/$run"
