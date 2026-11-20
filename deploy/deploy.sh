#!/usr/bin/env bash
# =============================================================================
# Deploy satu service di sebuah Docker Compose stack. Dipanggil Jenkins via SSH:
#     cd /opt/apps/<stack> && ./deploy.sh <service>
#
# Membaca .release/<service>.env (ditulis Jenkins):
#   SERVICE IMAGE_VAR IMAGE PULL HEALTH_CMD HEALTH_RETRIES HEALTH_INTERVAL ROLLBACK COMMIT BUILD
#
# Alur: lock → set <IMAGE_VAR>=<IMAGE> di .env → pull → hooks/pre-deploy.sh →
#       docker compose up -d <service> → health check → hooks/post-deploy.sh
# Bila gagal dan ROLLBACK=true, image sebelumnya dikembalikan.
#
# Bisa juga dipakai manual, mis. rollback ke image tertentu:
#     IMAGE=docker.io/user/klinik-api:41-abcd1234 ./deploy.sh api
# =============================================================================
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$0")")"
STACK_DIR="$PWD"

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deploy]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[deploy] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SERVICE_ARG="${1:-}"
[[ -n "$SERVICE_ARG" ]] || die "pemakaian: $0 <service>"

IMAGE_OVERRIDE="${IMAGE:-}"
REL_FILE=".release/${SERVICE_ARG}.env"
if [[ -f "$REL_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$REL_FILE"
fi
[[ -n "$IMAGE_OVERRIDE" ]] && IMAGE="$IMAGE_OVERRIDE"

SERVICE="${SERVICE:-$SERVICE_ARG}"
IMAGE_VAR="${IMAGE_VAR:-$(echo "$SERVICE" | tr '[:lower:]-' '[:upper:]_')_IMAGE}"
IMAGE="${IMAGE:-}"
PULL="${PULL:-true}"
HEALTH_CMD="${HEALTH_CMD:-}"
HEALTH_RETRIES="${HEALTH_RETRIES:-30}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"
ROLLBACK="${ROLLBACK:-true}"

[[ -n "$IMAGE" ]] || die "IMAGE kosong (cek $REL_FILE)"
[[ -f docker-compose.yml ]] || die "docker-compose.yml tidak ada di $STACK_DIR"
[[ -f .env ]] || die "File .env belum ada di $STACK_DIR — jalankan playbook Ansible atau salin dari .env.example"
command -v docker >/dev/null || die "docker belum terpasang"
docker compose version >/dev/null 2>&1 || die "plugin docker compose belum terpasang"

compose() { docker compose --env-file .env -f docker-compose.yml "$@"; }
export -f compose 2>/dev/null || true

# ---- lock: dua job (mis. api & web) bisa deploy ke stack yang sama bersamaan
exec 9>"$STACK_DIR/.deploy.lock"
if command -v flock >/dev/null; then
    log "menunggu lock stack..."
    flock -w 900 9 || die "timeout menunggu lock deploy"
fi

get_env() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2- || true; }
set_env() {
    local key="$1" val="$2" tmp
    if grep -qE "^${key}=" .env; then
        tmp="$(mktemp)"
        awk -v k="$key" -v v="$val" 'index($0, k"=")==1 { print k"="v; next } { print }' .env > "$tmp"
        cat "$tmp" > .env   # pertahankan permission/owner file
        rm -f "$tmp"
    else
        [[ -s .env && -n "$(tail -c1 .env)" ]] && echo >> .env
        printf '%s=%s\n' "$key" "$val" >> .env
    fi
}

PREV_IMAGE="$(get_env "$IMAGE_VAR")"
STARTED=0

rollback() {
    local reason="$1"
    warn "$reason"
    if [[ "$STARTED" == 1 ]]; then
        compose logs --tail=80 "$SERVICE" || true
    fi
    if [[ "$ROLLBACK" == "true" && -n "$PREV_IMAGE" && "$PREV_IMAGE" != "$IMAGE" ]]; then
        warn "rollback $IMAGE_VAR → $PREV_IMAGE"
        set_env "$IMAGE_VAR" "$PREV_IMAGE"
        if [[ "$STARTED" == 1 ]]; then
            compose up -d "$SERVICE" || warn "rollback gagal menjalankan ulang $SERVICE"
        fi
    elif [[ -z "$PREV_IMAGE" ]]; then
        set_env "$IMAGE_VAR" ""
    fi
    echo "$(date -Is) FAIL $SERVICE $IMAGE ${COMMIT:-} ${BUILD:-}" >> .release/history.log
    die "deploy $SERVICE gagal"
}

mkdir -p .release
log "stack   : $STACK_DIR"
log "service : $SERVICE"
log "image   : $IMAGE  (sebelumnya: ${PREV_IMAGE:-<belum ada>})"

set_env "$IMAGE_VAR" "$IMAGE"

if [[ "$PULL" == "true" ]]; then
    log "pull image..."
    compose pull "$SERVICE" || rollback "gagal pull image"
else
    docker image inspect "$IMAGE" >/dev/null 2>&1 || rollback "image $IMAGE tidak ada di server"
fi

if [[ -f hooks/pre-deploy.sh ]]; then
    log "menjalankan hooks/pre-deploy.sh"
    SERVICE="$SERVICE" IMAGE="$IMAGE" PREV_IMAGE="$PREV_IMAGE" bash hooks/pre-deploy.sh || rollback "pre-deploy hook gagal"
fi

log "docker compose up -d $SERVICE"
STARTED=1
compose up -d "$SERVICE" || rollback "docker compose up gagal"

if [[ -n "$HEALTH_CMD" ]]; then
    log "health check (maks ${HEALTH_RETRIES}x tiap ${HEALTH_INTERVAL}s): $HEALTH_CMD"
    ok=0
    for ((i = 1; i <= HEALTH_RETRIES; i++)); do
        if eval "$HEALTH_CMD" >/dev/null 2>&1; then ok=1; break; fi
        sleep "$HEALTH_INTERVAL"
    done
    [[ "$ok" == 1 ]] || rollback "health check gagal"
    log "health check OK (percobaan ke-$i)"
fi

if [[ -f hooks/post-deploy.sh ]]; then
    log "menjalankan hooks/post-deploy.sh"
    SERVICE="$SERVICE" IMAGE="$IMAGE" bash hooks/post-deploy.sh || warn "post-deploy hook gagal (deploy tetap dianggap sukses)"
fi

echo "$(date -Is) OK   $SERVICE $IMAGE ${COMMIT:-} ${BUILD:-}" >> .release/history.log
docker image prune -f >/dev/null 2>&1 || true
compose ps
log "deploy $SERVICE sukses ✔"
