#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/state"
CONF="$ROOT/nginx/conf.d/default.conf"
NETWORK="blue-green-net"
IMAGE="blue-green-app:latest"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"

mkdir -p "$STATE"

active() {
    cat "$STATE/active"
}

other() {
    [[ "$1" == "blue" ]] && echo "green" || echo "blue"
}

container_name() {
    echo "${1}-app"
}

check_health() {
    local env="$1"
    local name
    name="$(container_name "$env")"
    local deadline=$((SECONDS + HEALTH_TIMEOUT))

    echo "Waiting for $name to become healthy..."

    while (( SECONDS < deadline )); do
        local running health
        running="$(sudo docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)"
        health="$(sudo docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$name" 2>/dev/null || true)"

        if [[ "$running" == "true" && "$health" == "healthy" ]]; then
            echo "$name is healthy."
            return 0
        fi

        if [[ "$running" != "true" ]]; then
            echo "$name is not running yet."
        else
            echo "$name health status: $health"
        fi

        sleep 2
    done

    echo "ERROR: $name did not become healthy within ${HEALTH_TIMEOUT}s." >&2
    return 1
}
write_config() {
    local primary="$1"
    local canary_pct="${2:-0}"
    local standby
    standby="$(other "$primary")"

    local temp
    temp="$(mktemp "$ROOT/nginx/nginx-config.XXXXXX")"

    if (( canary_pct > 0 )); then
        cat > "$temp" <<NGINX
upstream app_backend {
    server ${primary}-app:3000 weight=$((100 - canary_pct));
    server ${standby}-app:3000 weight=${canary_pct};
}

server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://app_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX
    else
        cat > "$temp" <<NGINX
upstream app_backend {
    server ${primary}-app:3000;
}

server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://app_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX
    fi

    # Preserve the working configuration so a failed validation can be undone.
    cp "$CONF" "$STATE/config.previous"
    cp "$temp" "$CONF"
    rm -f "$temp"

    if ! sudo docker exec nginx-router nginx -t; then
        echo "Invalid NGINX config; restoring previous configuration." >&2
        cp "$STATE/config.previous" "$CONF"
        sudo docker exec nginx-router nginx -t
        return 1
    fi

    if ! sudo docker exec nginx-router nginx -s reload; then
        echo "NGINX reload failed; restoring previous configuration." >&2
        cp "$STATE/config.previous" "$CONF"
        sudo docker exec nginx-router nginx -t &&
            sudo docker exec nginx-router nginx -s reload
        return 1
    fi
}

check_route() {
    local expected="$1"
    local response
    local attempt

    for attempt in {1..5}; do
        response="$(curl -fsS --max-time 5 http://localhost/health 2>/dev/null || true)"
        if [[ "$response" == *"\"environment\": \"$expected\""* ]]; then
            echo "Traffic check passed: $expected is receiving traffic."
            return 0
        fi
        sleep 1
    done

    echo "ERROR: traffic did not reach expected environment: $expected" >&2
    return 1
}

show_status() {
    local current standby
    current="$(active)"
    standby="$(other "$current")"

    echo "Active environment:  $current"
    echo "Standby environment: $standby"
    echo "Last action:         $(cat "$STATE/last_action" 2>/dev/null || echo unknown)"
    echo
    sudo docker ps --filter name=blue-app --filter name=green-app \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

    echo
    echo "Active health:"
    curl -fsS --max-time 5 http://localhost/health || true
    echo
}

deploy() {
    local old target version
    old="$(active)"
    target="$(other "$old")"
    version="$(date -u +%Y%m%d%H%M%S)"

    echo "Deploying to standby environment: $target"
    echo "Building application image..."
    sudo docker build -t "$IMAGE" "$ROOT/app"

    # Replace only the standby container; keep the active one serving traffic.
    sudo docker rm -f "$(container_name "$target")" >/dev/null 2>&1 || true
    sudo docker run -d \
        --name "$(container_name "$target")" \
        --network "$NETWORK" \
        --network-alias "$(container_name "$target")" \
        --restart unless-stopped \
        --env APP_ENV="$target" \
        --env APP_VERSION="$version" \
        "$IMAGE"

    if ! check_health "$target"; then
        echo "Deployment aborted; traffic remains on $old."
        return 1
    fi

    if ! write_config "$target"; then
        echo "Switch failed; traffic should remain on $old."
        return 1
    fi

    if [[ "${SIMULATE_POST_SWITCH_FAILURE:-0}" == "1" ]] ||
       ! check_route "$target"; then
        echo "Post-switch check failed. Reverting to $old."

        if ! write_config "$old"; then
            echo "CRITICAL: Could not restore the previous NGINX configuration." >&2
            return 1
        fi

        if ! check_route "$old"; then
            echo "CRITICAL: Previous environment did not recover traffic." >&2
            return 1
        fi

        echo "$old" > "$STATE/active"
        echo "$target" > "$STATE/previous"
        echo "rollback" > "$STATE/last_action"
        echo "Automatic rollback successful: traffic restored to $old."
        return 1
    fi

    echo "$old" > "$STATE/previous"
    echo "$target" > "$STATE/active"
    echo "deploy" > "$STATE/last_action"

    echo "Deployment successful: $target, version $version"
}

rollback() {
    local current previous action
    current="$(active)"
    previous="$(cat "$STATE/previous")"
    action="$(cat "$STATE/last_action" 2>/dev/null || echo unknown)"

    # Undo a canary by routing 100% to the current active environment.
    if [[ "$action" == "canary" ]]; then
        check_health "$current"
        write_config "$current"
        check_route "$current"
        echo "rollback" > "$STATE/last_action"
        echo "Canary removed; 100% of traffic is back on $current."
        return
    fi

    if [[ "$previous" == "$current" ]]; then
        echo "No different previous environment is recorded."
        echo "Use 'rollback' after a successful deployment."
        return 1
    fi

    check_health "$previous"
    write_config "$previous"
    check_route "$previous"

    echo "$current" > "$STATE/previous"
    echo "$previous" > "$STATE/active"
    echo "rollback" > "$STATE/last_action"
    echo "Rollback complete. Active environment: $previous"
}

canary() {
    local percentage="${1:-}"

    if [[ ! "$percentage" =~ ^[0-9]+$ ]] ||
       (( percentage < 1 || percentage > 99 )); then
        echo "Usage: $0 canary <percentage from 1 to 99>" >&2
        return 2
    fi

    local current standby
    current="$(active)"
    standby="$(other "$current")"

    check_health "$current"
    check_health "$standby"
    write_config "$current" "$percentage"
    echo "canary" > "$STATE/last_action"

    echo "Canary enabled: approximately $percentage% to $standby, remainder to $current."
    echo "Note: NGINX weighted balancing is approximate over small request samples."
}

case "${1:-}" in
    deploy)
        deploy
        ;;
    rollback)
        rollback
        ;;
    status)
        show_status
        ;;
    canary)
        canary "${2:-}"
        ;;
    *)
        echo "Usage: $0 {deploy|rollback|status|canary <1-99>}"
        exit 2
        ;;
esac
