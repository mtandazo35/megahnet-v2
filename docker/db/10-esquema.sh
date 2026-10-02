#!/usr/bin/env bash
# Carga el esquema base. Lo ejecuta el contenedor de MariaDB UNA sola vez, la
# primera vez que arranca con la base vacia (asi funciona su punto de entrada).
# Si mas adelante quieres partir de cero: docker compose down -v
set -Eeuo pipefail

ESQUEMA=/megahnet-db/schema.sql
BASE="${MARIADB_DATABASE:-sistema}"

# En MariaDB 11 el cliente se llama 'mariadb'; 'mysql' sigue existiendo como
# enlace, pero no se puede dar por hecho. Nuestras herramientas invocan 'mysql',
# asi que si falta se crea el enlace dentro del contenedor.
if ! command -v mysql >/dev/null 2>&1 && command -v mariadb >/dev/null 2>&1; then
    ln -sf "$(command -v mariadb)" /usr/local/bin/mysql
    ln -sf "$(command -v mariadb-dump)" /usr/local/bin/mysqldump 2>/dev/null || true
fi

if [[ ! -f "$ESQUEMA" ]]; then
    echo "[esquema] no hay $ESQUEMA; se omite"
    exit 0
fi

echo "[esquema] cargando el esquema en '$BASE'"
# El punto de entrada de la imagen ya nos deja autenticados como root por socket.
mysql --protocol=socket -uroot -p"${MARIADB_ROOT_PASSWORD}" "$BASE" < "$ESQUEMA"
echo "[esquema] cargado"
