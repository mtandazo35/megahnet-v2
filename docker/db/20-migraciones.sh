#!/usr/bin/env bash
# Aplica las migraciones con NUESTRA libreria, la misma que va a usar el
# instalador en el servidor.
#
# Esto no es solo comodidad: hasta ahora esa libreria solo se habia probado
# contra un cliente de base de datos simulado. Aqui se ejecuta contra MariaDB
# de verdad cada vez que alguien levanta el entorno desde cero, asi que si
# alguna vez deja de funcionar, lo sabremos aqui y no en produccion.
set -Eeuo pipefail

LIB=/megahnet-installer/lib/migraciones.sh
DIR=/megahnet-db/migrations
BASE="${MARIADB_DATABASE:-sistema}"

if [[ ! -f "$LIB" ]]; then
    echo "[migraciones] no se encontro $LIB; se omiten"
    exit 0
fi
if [[ ! -d "$DIR" ]]; then
    echo "[migraciones] no hay carpeta $DIR; se omiten"
    exit 0
fi

# Las credenciales viajan por fichero de opciones, nunca por la linea de
# comandos (ahi las veria cualquiera con 'ps').
CNF="$(mktemp)"
chmod 600 "$CNF"
cat > "$CNF" <<FIN
[client]
protocol=socket
user=root
password=${MARIADB_ROOT_PASSWORD}
FIN
trap 'rm -f "$CNF"' EXIT

# shellcheck source=/dev/null
source "$LIB"

echo "[migraciones] aplicando sobre '$BASE'"
if MIGRACIONES_DB="$BASE" \
   MIGRACIONES_DIR="$DIR" \
   MIGRACIONES_DEFAULTS_FILE="$CNF" \
   migraciones_aplicar; then
    echo "[migraciones] estado final:"
    MIGRACIONES_DB="$BASE" MIGRACIONES_DIR="$DIR" MIGRACIONES_DEFAULTS_FILE="$CNF" \
        migraciones_estado || true
else
    # Parar aqui es deliberado: una base a medias es peor que una base vacia,
    # y es exactamente lo que el instalador actual deja pasar con su '|| true'.
    echo "[migraciones] FALLO: la base queda incompleta a proposito. Revisa el error de arriba."
    exit 1
fi
