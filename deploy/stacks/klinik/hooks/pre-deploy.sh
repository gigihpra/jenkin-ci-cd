#!/usr/bin/env bash
# Dipanggil deploy.sh SEBELUM `docker compose up -d <service>`.
# Env: SERVICE, IMAGE, PREV_IMAGE. Working dir: folder stack (/opt/apps/klinik).
# Exit != 0 → deploy dibatalkan & image dikembalikan.
set -Eeuo pipefail

compose() { docker compose --env-file .env -f docker-compose.yml "$@"; }

case "$SERVICE" in
    api)
        echo "[hook] ekstrak folder db/ (migrations + seed) dari $IMAGE"
        cid="$(docker create "$IMAGE")"
        trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
        rm -rf db.new
        docker cp "$cid:/app/db" db.new
        rm -rf db && mv db.new db

        echo "[hook] memastikan database berjalan"
        compose up -d --wait db

        # Image API berjalan sebagai uid 10001, sedangkan volume baru dibuat milik root.
        echo "[hook] memastikan volume uploads bisa ditulis aplikasi"
        compose run --rm --no-deps --user 0 --entrypoint sh api \
            -c 'mkdir -p /app/storage/uploads && chown 10001:10001 /app/storage/uploads'

        echo "[hook] atlas migrate apply"
        compose --profile tools run --rm migrate
        ;;
    *)
        : # service lain tidak butuh langkah tambahan
        ;;
esac
