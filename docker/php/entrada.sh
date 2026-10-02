#!/usr/bin/env bash
# Preparacion del contenedor de la aplicacion antes de arrancar Apache.
#
# Se ejecuta en CADA arranque y es idempotente: si algo ya esta hecho, no se
# repite. No toca nada fuera del contenedor.
set -Eeuo pipefail

RAIZ=/var/www/html

echo "[entrada] preparando el entorno local"

# --- .env ------------------------------------------------------------------
# El .env NO esta en el repositorio (ni debe estarlo). Se genera aqui a partir
# de las variables del compose, para que nadie tenga que escribirlo a mano ni
# se cuele una credencial en git.
if [[ ! -f "$RAIZ/.env" ]]; then
    {
        echo "# Generado por el contenedor para el entorno LOCAL. No subir a git."
        echo "DB_HOST=${DB_HOST:-db}"
        echo "DB_NAME=${DB_NAME:-sistema}"
        echo "DB_USER=${DB_USER:-megahnet}"
        echo "DB_PASSWORD=${DB_PASSWORD:-megahnet}"
        echo "BASE_URL=${BASE_URL:-http://localhost:8080/}"
        echo "APP_TITLE=${APP_TITLE:-MEGAHNET (local)}"
        # 0 = local. Con 1 el sistema intentaria hablar con el SRI de verdad.
        echo "ENVIROMENT=0"
        # 2 = ambiente de PRUEBAS del SRI. Nunca 1 (produccion) en local.
        echo "AMBIENTE=2"
        echo "RUTARESPALDOBD=/var/www/html/storage/respaldos"
    } > "$RAIZ/.env"
    chmod 640 "$RAIZ/.env"
    echo "[entrada] .env creado (apuntando a la base '${DB_NAME:-sistema}' en '${DB_HOST:-db}')"
fi

# --- carpetas de trabajo ---------------------------------------------------
# Estan en .gitignore, asi que en un clon limpio no existen y la aplicacion
# fallaria al escribir el primer PDF o la primera alerta.
for dir in storage storage/respaldos storage/update static uploads cache \
           facturaelectronica/public/archivos/ride \
           facturaelectronica/public/archivos/autorizados \
           facturaelectronica/public/archivos/firmados \
           facturaelectronica/public/archivos/generados; do
    mkdir -p "$RAIZ/$dir"
done
chown -R www-data:www-data "$RAIZ/storage" "$RAIZ/static" "$RAIZ/uploads" \
      "$RAIZ/cache" "$RAIZ/facturaelectronica" 2>/dev/null || true

# --- dependencias de composer ----------------------------------------------
if [[ ! -d "$RAIZ/vendor" ]]; then
    echo "[entrada] instalando dependencias de composer (la primera vez tarda)"
    composer install --no-interaction --no-progress --working-dir="$RAIZ" \
        || echo "[entrada] AVISO: composer fallo; la aplicacion puede no funcionar entera"
fi

# --- esperar a la base de datos --------------------------------------------
# Apache arrancaria igual, pero la primera pagina daria un error feo de conexion.
echo -n "[entrada] esperando a la base de datos"
for _ in $(seq 1 60); do
    if mysqladmin ping -h"${DB_HOST:-db}" -u"${DB_USER:-megahnet}" \
         -p"${DB_PASSWORD:-megahnet}" --silent >/dev/null 2>&1; then
        echo " lista"
        break
    fi
    echo -n "."
    sleep 2
done

echo "[entrada] listo: http://localhost:${PUERTO_WEB:-8080}/"
exec "$@"
