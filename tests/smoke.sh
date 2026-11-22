#!/usr/bin/env bash
# Prueba de humo end-to-end: PKI, exportación, conexión real, revocación y persistencia.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
export SMOKE_CLIENT_DIR="$WORK/client" SMOKE_MOCK_DIR="$WORK/mock"
mkdir -p "$SMOKE_CLIENT_DIR" "$SMOKE_MOCK_DIR"
cp "$ROOT/tests/mock-http.sh" "$SMOKE_MOCK_DIR/"
chmod 777 "$SMOKE_MOCK_DIR"

dc() { docker compose -p ovpn-smoke --project-directory "$ROOT" --env-file "$ROOT/tests/smoke.env" \
    -f "$ROOT/compose.yaml" -f "$ROOT/tests/compose.smoke.yaml" "$@"; }

pass() { printf '\033[32m✔ %s\033[0m\n' "$*"; }
fail() {
    printf '\033[31m✘ %s\033[0m\n' "$*"
    dc logs --no-color --tail 80 || true
    exit 1
}

cleanup() {
    dc --profile test --profile duckdns down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

wait_healthy() {
    local svc=${1:-openvpn}
    for _ in $(seq 1 60); do
        [[ $(docker inspect -f '{{.State.Health.Status}}' "$(dc ps -q "$svc")" 2>/dev/null) == healthy ]] && return 0
        sleep 2
    done
    fail "$svc no llegó a estado healthy"
}

# Arranca un cliente con el perfil dado y espera el resultado (ok|fail).
try_client() {
    local user=$1 expect=$2 logs
    cp "$WORK/$user.ovpn" "$SMOKE_CLIENT_DIR/client.ovpn"
    local cid
    cid=$(dc --profile test run -d --rm --no-deps client)
    for _ in $(seq 1 30); do
        logs=$(docker logs "$cid" 2>&1 || true)
        if grep -q 'Initialization Sequence Completed' <<<"$logs"; then
            if [[ $expect == ok ]]; then
                docker exec "$cid" ping -c 2 -W 2 10.99.0.1 >/dev/null || fail "$user conectó pero no hay tráfico por el túnel"
                if grep -q 'Options error' <<<"$logs"; then fail "el cliente reporta 'Options error' en la configuración recibida"; fi
                docker rm -f "$cid" >/dev/null
                pass "$user se conecta y hay tráfico por el túnel"
                return
            fi
            docker rm -f "$cid" >/dev/null
            fail "$user se conectó pero debía ser rechazado"
        fi
        sleep 1
    done
    docker rm -f "$cid" >/dev/null 2>&1 || true
    if [[ $expect == fail ]]; then
        dc logs openvpn 2>&1 | grep 'certificate revoked' >/dev/null || fail "$user no conectó, pero el servidor no reporta revocación"
        pass "$user es rechazado (certificado revocado)"
    else
        echo "$logs" | tail -20
        fail "$user no logró conectarse"
    fi
}

echo "== build"
docker build -q -t ghcr.io/editech-dev/openvpn:smoke "$ROOT/openvpn" >/dev/null && pass "imagen construida"

echo "== arranque"
dc up -d openvpn
wait_healthy && pass "servidor healthy"

echo "== exportación"
for u in alice bob; do
    dc exec -T openvpn ovpnctl export "$u" >"$WORK/$u.ovpn"
    for tag in '<ca>' '<cert>' '<key>' '<tls-crypt>' 'remote openvpn 1194'; do
        grep -qF "$tag" "$WORK/$u.ovpn" || fail "perfil de $u sin '$tag'"
    done
done
if grep -x 'persist-tun' "$WORK/alice.ovpn" >/dev/null; then
    fail "el perfil incluye persist-tun: impediría re-resolver el dominio si cambia la IP"
fi
grep -x 'connect-retry 2 30' "$WORK/alice.ovpn" >/dev/null || fail "el perfil no limita la espera entre reintentos"
grep -x 'server-poll-timeout 10' "$WORK/alice.ovpn" >/dev/null || fail "el perfil no limita la espera a una IP que no responde"
pass "perfiles exportados con material inline"
"$ROOT/scripts/export-clients.sh" --project-dir "$ROOT" --out "$WORK/exports" \
    -- -p ovpn-smoke --env-file "$ROOT/tests/smoke.env" -f "$ROOT/compose.yaml" -f "$ROOT/tests/compose.smoke.yaml" >/dev/null
[[ -s $WORK/exports/alice.ovpn && -s $WORK/exports/bob.ovpn ]] || fail "export-clients.sh no generó los perfiles"
[[ $(stat -c %a "$WORK/exports/alice.ovpn") == 600 ]] || fail "permisos del perfil distintos de 600"
pass "scripts/export-clients.sh exporta todos los usuarios con permisos 600"

echo "== conexión"
try_client alice ok
try_client bob ok

echo "== revocación (quitar bob de OVPN_USERS)"
ca_before=$(dc exec -T openvpn sh -c 'openssl x509 -in /etc/openvpn/pki/ca.crt -noout -fingerprint')
OVPN_USERS=alice dc up -d openvpn
wait_healthy
dc exec -T openvpn ovpnctl users list | grep -E '^bob +revocado' >/dev/null || fail "bob no aparece revocado"
pass "bob revocado al quitarlo de la lista"
try_client bob fail
try_client alice ok

echo "== persistencia"
OVPN_USERS=alice dc down
OVPN_USERS=alice dc up -d openvpn
wait_healthy
ca_after=$(dc exec -T openvpn sh -c 'openssl x509 -in /etc/openvpn/pki/ca.crt -noout -fingerprint')
[[ $ca_before == "$ca_after" ]] || fail "la CA cambió tras recrear el contenedor"
try_client alice ok
pass "PKI persistente tras down/up"

echo "== revocación en caliente y reemisión"
cp "$WORK/alice.ovpn" "$SMOKE_CLIENT_DIR/client.ovpn"
cid=$(dc --profile test run -d --rm --no-deps client)
for _ in $(seq 1 30); do
    docker logs "$cid" 2>&1 | grep 'Initialization Sequence Completed' >/dev/null && break
    sleep 1
done
seen=0
for _ in $(seq 1 15); do # status.log se refresca cada 10 s
    if dc exec -T openvpn ovpnctl status | grep '^alice ' >/dev/null; then seen=1 && break; fi
    sleep 2
done
((seen)) || fail "alice no aparece en ovpnctl status"
OVPN_USERS=alice dc exec -T openvpn ovpnctl users revoke alice
gone=0
for _ in $(seq 1 15); do  # status.log se refresca cada 10 s
    if ! dc exec -T openvpn ovpnctl status | grep '^alice ' >/dev/null; then gone=1 && break; fi
    sleep 2
done
((gone)) || fail "alice sigue conectada tras revocarla"
docker rm -f "$cid" >/dev/null
pass "revoke desconecta al usuario al instante"
dc exec -T openvpn ovpnctl users reissue alice
dc exec -T openvpn ovpnctl export alice >"$WORK/alice.ovpn"
try_client alice ok
pass "reissue emite un perfil nuevo y funcional"

echo "== backup y restauración"
CA=(sh -c 'openssl x509 -in /etc/openvpn/pki/ca.crt -noout -fingerprint')
ca_before=$(dc exec -T openvpn "${CA[@]}")
SC=(-- -p ovpn-smoke --env-file "$ROOT/tests/smoke.env" -f "$ROOT/compose.yaml" -f "$ROOT/tests/compose.smoke.yaml")
OVPN_USERS=alice SMOKE_SERVER_IP=172.30.99.30 "$ROOT/scripts/backup-pki.sh" backup --out "$WORK/bk" "${SC[@]}" >/dev/null 2>&1
backup=$(ls "$WORK"/bk/*.tar.gz)
tar -tzf "$backup" | grep 'pki/ca.crt$' >/dev/null || fail "el backup no contiene la CA"
OVPN_USERS=alice dc down -v
OVPN_USERS=alice SMOKE_SERVER_IP=172.30.99.30 "$ROOT/scripts/backup-pki.sh" restore "$backup" --yes "${SC[@]}" >/dev/null 2>&1
OVPN_USERS=alice dc up -d openvpn
wait_healthy
[[ $(dc exec -T openvpn "${CA[@]}") == "$ca_before" ]] || fail "la CA restaurada no coincide"
try_client alice ok
pass "backup → borrar volumen → restore conserva la CA y los perfiles existentes"

echo "== apagado limpio (SIGTERM llega a openvpn y avisa a los clientes)"
cp "$WORK/alice.ovpn" "$SMOKE_CLIENT_DIR/client.ovpn"
cid=$(dc --profile test run -d --rm --no-deps client)
for _ in $(seq 1 30); do
    docker logs "$cid" 2>&1 | grep 'Initialization Sequence Completed' >/dev/null && break
    sleep 1
done
t0=$(date +%s)
OVPN_USERS=alice dc restart -t 10 openvpn
elapsed=$(($(date +%s) - t0))
if dc logs openvpn 2>&1 | grep 'Unexpected error when forwarding signal' >/dev/null; then
    fail "tini no puede reenviar señales a openvpn"
fi
((elapsed < 9)) || fail "el reinicio tardó ${elapsed}s: openvpn no atiende SIGTERM (lo mata SIGKILL)"
reconnected=0
for _ in $(seq 1 20); do
    if [[ $(docker logs "$cid" 2>&1 | grep -c 'Initialization Sequence Completed') -ge 2 ]]; then reconnected=1 && break; fi
    sleep 1
done
docker rm -f "$cid" >/dev/null
((reconnected)) || fail "el cliente no se reconectó en 20 s tras reiniciar el servidor"
pass "reinicio limpio en ${elapsed}s y el cliente se reconecta solo"

echo "== cambio de IP del servidor bajo el mismo nombre (escenario DuckDNS)"
cp "$WORK/alice.ovpn" "$SMOKE_CLIENT_DIR/client.ovpn"
cid=$(dc --profile test run -d --rm --no-deps client)
for _ in $(seq 1 30); do
    docker logs "$cid" 2>&1 | grep 'Initialization Sequence Completed' >/dev/null && break
    sleep 1
done
docker logs "$cid" 2>&1 | grep 'link remote: \[AF_INET\]172.30.99.10' >/dev/null || fail "el cliente no conectó a la IP inicial"
OVPN_USERS=alice SMOKE_SERVER_IP=172.30.99.20 dc up -d openvpn
moved=0
for _ in $(seq 1 40); do # server-poll-timeout 10: debe seguir al servidor en ~15 s
    if docker logs "$cid" 2>&1 | grep 'link remote: \[AF_INET\]172.30.99.20' >/dev/null &&
        docker exec "$cid" ping -c 1 -W 2 10.99.0.1 >/dev/null 2>&1; then
        moved=1 && break
    fi
    sleep 1
done
docker rm -f "$cid" >/dev/null
((moved)) || fail "el cliente no siguió al servidor a su nueva IP"
pass "el cliente re-resuelve el nombre y reconecta a la nueva IP del servidor"
OVPN_USERS=alice dc up -d openvpn
wait_healthy

echo "== validación de configuración"
# Los contenedores efímeros usan otra IP para no chocar con la del servidor en marcha.
out=$(OVPN_USERS='mal usuario!' SMOKE_SERVER_IP=172.30.99.30 dc run --rm --no-deps -T openvpn ovpnctl users list 2>&1) &&
    fail "aceptó un nombre de usuario inválido"
grep 'Usuario inválido' <<<"$out" >/dev/null || fail "falló por otro motivo: $out"
pass "rechaza usuarios inválidos"

echo "== duckdns (servidor simulado)"
dc --profile test up -d mock
OVPN_USERS=alice dc --profile duckdns up -d duckdns
wait_healthy duckdns
logs=$(dc logs --no-color duckdns 2>&1)
grep 'IP actualizada a 203.0.113.7' <<<"$logs" >/dev/null || fail "duckdns no registró la actualización: $logs"
grep 'domains=prueba&token=test-token-ok-123' "$SMOKE_MOCK_DIR/requests.log" >/dev/null || fail "duckdns no llamó al servicio"
if grep 'test-token-ok-123' <<<"$logs" >/dev/null; then fail "el token aparece en los logs"; fi
if docker top "$(dc ps -q duckdns)" -o args 2>/dev/null | grep 'test-token' >/dev/null; then fail "el token aparece en la lista de procesos"; fi
[[ $(docker inspect -f '{{.Config.User}}' "$(dc ps -q duckdns)") == 65534:65534 ]] || fail "duckdns no corre como nobody"
pass "duckdns actualiza la IP, queda healthy y no expone el token"
OVPN_USERS=alice DUCKDNS_TOKEN=bad-token-12345 dc --profile duckdns up -d duckdns
for _ in $(seq 1 20); do
    dc logs --no-color duckdns 2>&1 | grep 'respondió KO' >/dev/null && break
    sleep 1
done
dc logs --no-color duckdns 2>&1 | grep 'respondió KO' >/dev/null || fail "duckdns no informa un token rechazado"
pass "duckdns informa claramente un token o subdominio rechazado (KO)"

printf '\n\033[32mTodas las pruebas pasaron\033[0m\n'
