#!/usr/bin/env bash
# Exporta los perfiles .ovpn de los usuarios activos.
set -Eeuo pipefail
# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"

usage() {
    cat <<'USAGE'
Uso: scripts/export-clients.sh [opciones] [-- args extra para docker compose]

  -u, --user NOMBRE   Exporta solo ese usuario (repetible). Por defecto: todos los activos.
  -o, --out DIR       Carpeta de salida (por defecto: ./exports)
  -s, --stdout        Imprime el perfil por stdout (requiere un único --user)
  -z, --zip           Además empaqueta los perfiles en DIR/clients-AAAAMMDD-HHMMSS.zip
      --project-dir D Directorio del proyecto compose (por defecto: raíz del repo)
  -h, --help          Muestra esta ayuda

Los .ovpn contienen la llave privada del usuario: compártelos solo por un canal
seguro y bórralos cuando ya no los necesites.
USAGE
}

users=()
out="$PROJECT_DIR/exports"
to_stdout=0
zip=0
while (($#)); do
    case $1 in
        -u | --user) users+=("${2:?Falta el nombre}"); shift 2 ;;
        -o | --out) out=${2:?Falta la carpeta}; shift 2 ;;
        -s | --stdout) to_stdout=1; shift ;;
        -z | --zip) zip=1; shift ;;
        --project-dir) PROJECT_DIR=${2:?}; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        --) shift; COMPOSE_ARGS=("$@"); break ;;
        *) usage; die "Opción desconocida: $1" ;;
    esac
done

require_docker

if ((to_stdout)); then
    ((${#users[@]} == 1)) || die "--stdout requiere exactamente un --user"
    ovpnctl export "${users[0]}"
    exit 0
fi

if ((${#users[@]} == 0)); then
    mapfile -t users < <(ovpnctl users active)
    ((${#users[@]})) || die "No hay usuarios activos (revisa OVPN_USERS en .env y ejecuta 'make apply')"
fi

umask 077
mkdir -p "$out"
chmod 700 "$out"

exported=()
for u in "${users[@]}"; do
    tmp=$(mktemp "$out/.${u}.XXXXXX")
    if ovpnctl export "$u" >"$tmp"; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$out/$u.ovpn"
        exported+=("$out/$u.ovpn")
        msg "✔ $out/$u.ovpn"
    else
        rm -f "$tmp"
        die "No se pudo exportar '$u'"
    fi
done

if ((zip)); then
    command -v zip >/dev/null || die "zip no está instalado (apt install zip)"
    archive="$out/clients-$(date +%Y%m%d-%H%M%S).zip"
    zip -qj "$archive" "${exported[@]}"
    chmod 600 "$archive"
    msg "✔ $archive"
fi

msg ""
msg "AVISO: estos archivos contienen llaves privadas. Envíalos por un canal seguro."
