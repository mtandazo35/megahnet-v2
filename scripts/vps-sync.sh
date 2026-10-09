#!/usr/bin/env bash
# =============================================================================
#  vps-sync.sh - envia a un VPS de pruebas SOLO lo que cambio en tu copia local
#
#  Uso (desde cualquier carpeta del repositorio):
#      scripts/vps-sync.sh plan       muestra que se enviaria; no toca nada
#      scripts/vps-sync.sh aplicar    respalda, envia, verifica y revierte si falla
#      scripts/vps-sync.sh deshacer   restaura el ultimo respaldo
#
#  Configuracion: variables de entorno o un archivo .vps.env en la raiz del
#  repositorio (NO se sube a git). Si una variable esta en las dos partes, gana
#  el entorno.
#      VPS_HOST     usuario@ip. Obligatoria. "local" = simulacion para pruebas.
#      VPS_PATH     carpeta de la aplicacion en el VPS      (def. /var/www/megahnet)
#      VPS_PORT     puerto SSH                              (def. 22)
#      VPS_OWNER    dueno de lo enviado                     (def. www-data:www-data;
#                   vacio = no cambiar el dueno)
#      VPS_BACKUP   carpeta de respaldos en el VPS          (def. ~/vps-sync-backups)
#
#  Que se envia: lo que git ve en tu copia (versionado + nuevo sin ignorar),
#  menos docker/, docs/ y las pruebas de este script. Lo ignorado por git
#  (.env, storage/, facturaelectronica/, vendor/, firmas) NO viaja nunca.
#
#  Compara por contenido (sha256), no por fecha: solo viaja lo realmente distinto.
#  Antes de pisar nada guarda el original en el VPS; si la copia no verifica o
#  algun .php no pasa `php -l`, devuelve todo a como estaba.
# =============================================================================
set -Eeuo pipefail

RAIZ="${REPO_DIR:-}"
if [[ -z "$RAIZ" ]]; then
    RAIZ="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "No estas dentro de un repositorio git." >&2
        exit 1
    }
fi
cd "$RAIZ"

# .vps.env solo asigna lo que el entorno no haya definido.
if [[ -f .vps.env ]]; then
    while IFS='=' read -r k v || [[ -n "${k:-}" ]]; do
        v="${v%$'\r'}"; v="${v%\"}"; v="${v#\"}"
        [[ "$k" =~ ^VPS_[A-Z_]+$ ]] || continue
        [[ -n "${!k+x}" ]] || export "$k=$v"
    done < .vps.env
fi

VPS_HOST="${VPS_HOST:-}"
VPS_PATH="${VPS_PATH:-/var/www/megahnet}"
VPS_PORT="${VPS_PORT:-22}"
VPS_OWNER="${VPS_OWNER-www-data:www-data}"
VPS_BACKUP="${VPS_BACKUP:-\$HOME/vps-sync-backups}"   # \$HOME lo expande el VPS
EXCLUIR="${VPS_EXCLUIR:-^(docker|docs)/|^\.vps\.env\$|^\.(gitignore|gitattributes|dockerignore)\$|^scripts/tests/}"
LINT_CMD="${LINT_CMD:-php -l}"

# El host key no se verifica a proposito: las IP de pruebas se reutilizan.
SSH_OPTS=(-p "$VPS_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

if [[ -z "$VPS_HOST" ]]; then
    echo "Falta VPS_HOST (por ejemplo root@192.0.2.10). Definelo en .vps.env o en el entorno." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

remoto() {
    if [[ "$VPS_HOST" == "local" ]]; then
        bash -c "$1"
    else
        ssh "${SSH_OPTS[@]}" "$VPS_HOST" "$1"
    fi
}

# ---------------------------------------------------------------------------
# Calcula que cambia. Deja en $TMP: lista.*, local.sha, remoto.sha,
# cambios.*, nuevos.txt, modificados.*
# ---------------------------------------------------------------------------
preparar() {
    git ls-files -z --cached --others --exclude-standard \
        | tr '\0' '\n' | LC_ALL=C sort -u | { grep -Ev "$EXCLUIR" || true; } \
        | while IFS= read -r f; do [[ -f "$f" ]] && printf '%s\n' "$f"; done > "$TMP/lista.txt" || true

    if [[ ! -s "$TMP/lista.txt" ]]; then
        echo "No hay archivos para enviar." >&2
        exit 1
    fi
    tr '\n' '\0' < "$TMP/lista.txt" > "$TMP/lista.0"

    xargs -0 sha256sum < "$TMP/lista.0" > "$TMP/local.sha"
    # Lo que no exista todavia en el VPS simplemente no aparece: cuenta como nuevo.
    remoto "cd \"$VPS_PATH\" 2>/dev/null && xargs -0 sha256sum 2>/dev/null; true" \
        < "$TMP/lista.0" > "$TMP/remoto.sha" || true

    # sha256sum: 64 caracteres de hash, 2 de separador, y la ruta desde la col. 67.
    # OJO: no se usa NR==FNR para distinguir el primer archivo. Si el primero esta
    # vacio (un VPS sin nada todavia), NR==FNR sigue siendo cierto durante el
    # segundo y awk lo leeria como si fuera el primero: concluiria "ya esta al
    # dia" sin enviar nada. Se distingue por nombre de archivo.
    awk 'FILENAME == ARGV[1] { r[substr($0,67)] = substr($0,1,64); next }
         { p = substr($0,67); if (!(p in r) || r[p] != substr($0,1,64)) print p }' \
        "$TMP/remoto.sha" "$TMP/local.sha" > "$TMP/cambios.txt"
    awk 'FILENAME == ARGV[1] { r[substr($0,67)] = 1; next } { if (!($0 in r)) print }' \
        "$TMP/remoto.sha" "$TMP/cambios.txt" > "$TMP/nuevos.txt"
    { grep -vxFf "$TMP/nuevos.txt" "$TMP/cambios.txt" || true; } > "$TMP/modificados.txt"

    tr '\n' '\0' < "$TMP/cambios.txt"     > "$TMP/cambios.0"
    tr '\n' '\0' < "$TMP/modificados.txt" > "$TMP/modificados.0"

    N_TOTAL="$(wc -l < "$TMP/lista.txt" | tr -d ' ')"
    N_CAMBIOS="$(wc -l < "$TMP/cambios.txt" | tr -d ' ')"
    N_NUEVOS="$(wc -l < "$TMP/nuevos.txt" | tr -d ' ')"
    N_MODIF="$(wc -l < "$TMP/modificados.txt" | tr -d ' ')"
}

resumen() {
    echo "Destino: $VPS_HOST:$VPS_PATH"
    echo "Archivos controlados: $N_TOTAL | nuevos=$N_NUEVOS modificados=$N_MODIF iguales=$((N_TOTAL - N_CAMBIOS))"
    if (( N_CAMBIOS > 0 )); then
        echo "--- se enviarian:"
        head -40 "$TMP/cambios.txt" | while IFS= read -r f; do
            if grep -qxF "$f" "$TMP/nuevos.txt"; then echo "  + $f"; else echo "  ~ $f"; fi
        done
        (( N_CAMBIOS > 40 )) && echo "  ... y $((N_CAMBIOS - 40)) mas"
    fi
    # Avisos: cosas que enviar el archivo no basta para que surtan efecto.
    grep -q '^db/migrations/' "$TMP/cambios.txt" \
        && echo "AVISO: hay migraciones nuevas en db/migrations/. Este script no las aplica: hay que aplicarlas en el VPS."
    grep -qE '^composer\.(json|lock)$' "$TMP/cambios.txt" \
        && echo "AVISO: cambio composer.json/lock. En el VPS falta ejecutar 'composer install --no-dev'."
    grep -qE '^(install\.sh|installer/)' "$TMP/cambios.txt" \
        && echo "AVISO: cambio el instalador; los cambios no se aplican hasta volver a ejecutarlo."
    grep -qE '^cron/' "$TMP/cambios.txt" \
        && echo "AVISO: cambiaron tareas programadas (cron/). Las unidades systemd ya instaladas no se regeneran solas."
    return 0
}

# ---------------------------------------------------------------------------
revertir() {
    local ts="$1"
    echo "Revirtiendo al respaldo $ts ..."
    remoto "cd \"$VPS_PATH\" || exit 1
            [ -f \"$VPS_BACKUP/$ts.tar.gz\" ] && tar xzf \"$VPS_BACKUP/$ts.tar.gz\"
            [ -s \"$VPS_BACKUP/$ts.nuevos\" ] && xargs -d '\n' -r rm -f -- < \"$VPS_BACKUP/$ts.nuevos\"
            mv \"$VPS_BACKUP/$ts.nuevos\" \"$VPS_BACKUP/$ts.nuevos.deshecho\"
            true"
}

permisos() {
    remoto "cd \"$VPS_PATH\" && xargs -0 -r chmod u=rw,go=r --" < "$TMP/cambios.0" || return 1
    { grep -z '\.sh$' "$TMP/cambios.0" || true; } \
        | remoto "cd \"$VPS_PATH\" && xargs -0 -r chmod 0755 --" || return 1
    if [[ -n "$VPS_OWNER" ]]; then
        remoto "cd \"$VPS_PATH\" && xargs -0 -r chown \"$VPS_OWNER\" --" < "$TMP/cambios.0" || return 1
    fi
}

verificar() {
    remoto "cd \"$VPS_PATH\" && xargs -0 sha256sum" < "$TMP/cambios.0" 2>/dev/null \
        | awk '{ print substr($0,1,64) " " substr($0,67) }' | LC_ALL=C sort > "$TMP/despues.remoto" || return 1
    xargs -0 sha256sum < "$TMP/cambios.0" \
        | awk '{ print substr($0,1,64) " " substr($0,67) }' | LC_ALL=C sort > "$TMP/despues.local"
    if ! diff -q "$TMP/despues.local" "$TMP/despues.remoto" > /dev/null; then
        echo "La copia no coincide con el original:" >&2
        diff "$TMP/despues.local" "$TMP/despues.remoto" | head -10 >&2
        return 1
    fi
}

sintaxis() {
    { grep -z '\.php$' "$TMP/cambios.0" || true; } > "$TMP/php.0"
    [[ -s "$TMP/php.0" ]] || return 0
    local bin="${LINT_CMD%% *}" salida
    if ! remoto "command -v $bin >/dev/null 2>&1"; then
        echo "AVISO: '$bin' no esta instalado en el VPS; se omite la comprobacion de sintaxis." >&2
        return 0
    fi
    if ! salida="$(remoto "cd \"$VPS_PATH\" && xargs -0 -r -n1 $LINT_CMD" < "$TMP/php.0" 2>&1)"; then
        echo "Error de sintaxis en lo enviado:" >&2
        printf '%s\n' "$salida" | { grep -v '^No syntax errors' || true; } | head -15 >&2
        return 1
    fi
}

enviar() {
    tar -c --null -T "$TMP/cambios.0" | remoto "cd \"$VPS_PATH\" && tar -x --no-same-owner" || return 1
    permisos  || return 1
    verificar || return 1
    sintaxis  || return 1
}

# ---------------------------------------------------------------------------
cmd_plan() {
    preparar
    resumen
    (( N_CAMBIOS == 0 )) && echo "Nada que enviar: el VPS ya esta al dia."
    return 0
}

cmd_aplicar() {
    preparar
    if (( N_CAMBIOS == 0 )); then
        echo "Nada que enviar: el VPS ya esta al dia."
        return 0
    fi
    resumen

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    remoto "mkdir -p \"$VPS_PATH\" \"$VPS_BACKUP\""

    # 1) El original de todo lo que se va a pisar, y la lista de lo que es nuevo.
    if [[ -s "$TMP/modificados.txt" ]]; then
        remoto "cd \"$VPS_PATH\" && tar czf \"$VPS_BACKUP/$ts.tar.gz\" --null -T -" \
            < "$TMP/modificados.0"
    fi
    remoto "cat > \"$VPS_BACKUP/$ts.nuevos\"" < "$TMP/nuevos.txt"

    # 2) Enviar, ajustar permisos, verificar y comprobar sintaxis. Si algo falla, todo atras.
    if ! enviar; then
        echo "FALLO el envio." >&2
        revertir "$ts"
        echo "El VPS quedo como estaba antes." >&2
        return 2
    fi

    echo "OK: $N_CAMBIOS archivo(s) enviados y verificados. Respaldo: $VPS_BACKUP/$ts"
    echo "Para deshacer: scripts/vps-sync.sh deshacer"
}

cmd_deshacer() {
    local ts
    ts="$(remoto "ls -1 \"$VPS_BACKUP\" 2>/dev/null | sed -n 's/\\.nuevos\$//p' | sort | tail -1")"
    if [[ -z "$ts" ]]; then
        echo "No hay respaldos que deshacer." >&2
        return 1
    fi
    revertir "$ts"
    echo "Listo: el VPS volvio al estado anterior a $ts."
}

case "${1:-}" in
    plan)     cmd_plan ;;
    aplicar)  cmd_aplicar ;;
    deshacer) cmd_deshacer ;;
    *)        sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
