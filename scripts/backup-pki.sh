#!/usr/bin/env bash
# Copia de seguridad / restauración del volumen de OpenVPN (CA, certificados, llaves).
# La PKI es lo único irrecuperable: sin ella hay que reemitir todos los perfiles.
set -Eeuo pipefail
# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"

usage() {
    cat <<'USAGE'
Uso:
  scripts/backup-pki.sh backup  [--out DIR] [--age-recipient CLAVE | --gpg]
  scripts/backup-pki.sh restore ARCHIVO --yes

  Ambos aceptan al final "-- <args de docker compose>" (ej. -- -p otro-proyecto).

  --out DIR            Carpeta destino (por defecto: ./backups)
  --age-recipient K    Cifra con age para la clave pública K (recomendado)
  --gpg                Cifra con gpg simétrico (pide contraseña)
  --yes                Confirma la restauración (SOBRESCRIBE la PKI actual)

Sin cifrado el archivo contiene llaves privadas en claro: guárdalo en un lugar seguro.
USAGE
}

backup() {
    local out="$PROJECT_DIR/backups" age_rcpt="" gpg=0
    while (($#)); do
        case $1 in
            --out) out=${2:?}; shift 2 ;;
            --age-recipient) age_rcpt=${2:?}; shift 2 ;;
            --gpg) gpg=1; shift ;;
            *) usage; die "Opción desconocida: $1" ;;
        esac
    done
    umask 077
    mkdir -p "$out"
    local file
    file="$out/openvpn-pki-$(date +%Y%m%d-%H%M%S).tar.gz"
    run_oneoff --entrypoint tar openvpn -czf - -C /etc/openvpn . >"$file"
    if ! tar -tzf "$file" 2>/dev/null | grep 'pki/ca.crt$' >/dev/null; then
        rm -f "$file"
        die "El backup no contiene una PKI válida (¿el servicio se ha iniciado alguna vez en este proyecto?)"
    fi
    if [[ -n $age_rcpt ]]; then
        command -v age >/dev/null || die "age no está instalado"
        age -r "$age_rcpt" -o "$file.age" "$file" && rm -f "$file" && file="$file.age"
    elif ((gpg)); then
        command -v gpg >/dev/null || die "gpg no está instalado"
        gpg --symmetric --cipher-algo AES256 -o "$file.gpg" "$file" && rm -f "$file" && file="$file.gpg"
    else
        msg "AVISO: backup sin cifrar (contiene llaves privadas)."
    fi
    msg "✔ Backup: $file"
}

restore() {
    local file=${1:-} yes=${2:-}
    [[ -f $file ]] || die "Archivo no encontrado: $file"
    [[ $yes == --yes ]] || die "La restauración sobrescribe la PKI actual. Repite con --yes"
    # Se descifra a un temporal privado y se valida ANTES de tocar la PKI actual.
    umask 077
    local plain
    plain=$(mktemp)
    trap 'rm -f "$plain"' RETURN
    case $file in
        *.age) age -d -o "$plain" "$file" ;;
        *.gpg) gpg -d -o "$plain" --yes "$file" ;;
        *) cp "$file" "$plain" ;;
    esac
    tar -tzf "$plain" 2>/dev/null | grep 'pki/ca.crt$' >/dev/null || die "El archivo no es un backup válido de la PKI"
    dc stop openvpn >/dev/null 2>&1 || true
    run_oneoff --entrypoint sh openvpn \
        -c 'find /etc/openvpn -mindepth 1 -delete && tar -xzf - -C /etc/openvpn' <"$plain"
    msg "✔ PKI restaurada. Arranca con: make up"
}

args=()
split_compose_args args "$@"
set -- "${args[@]}"
require_docker
case ${1:-} in
    backup) shift; backup "$@" ;;
    restore) shift; restore "$@" ;;
    *) usage; exit 2 ;;
esac
