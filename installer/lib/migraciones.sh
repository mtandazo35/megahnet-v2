#!/usr/bin/env bash
# ============================================================================
#  migraciones.sh — aplica las migraciones SQL de megahnet dejando rastro
#                   y PARANDO en la primera que falle.
#
#  El instalador actual (../megahnet/install.sh, ~linea 243) hace esto:
#
#      mysql "${DB_NAME}" < "$mig" 2>&1 | grep -v -E '^Warning:' || true
#
#  Ese `|| true` se traga el fallo: si una migracion revienta, la instalacion
#  sigue y la base queda a medias sin que nadie se entere. Ademas no queda
#  registro de que se aplico ni cuando, asi que no hay forma de saber en que
#  estado esta una maquina sin ir a mirar las tablas a mano.
#
#  Esta libreria:
#    - lleva una tabla de control (que archivo, que suma, cuando, cuanto tardo,
#      como acabo),
#    - aplica en orden solo lo que falta,
#    - corta en seco al primer error y devuelve codigo != 0,
#    - avisa (y por defecto aborta) si una migracion ya aplicada cambio de
#      contenido, porque eso significa que dos maquinas con el mismo numero de
#      migracion pueden tener esquemas distintos.
#
#  SE PUEDE USAR DE DOS FORMAS
#
#    1) Cargada desde el instalador:
#
#         source installer/lib/migraciones.sh
#         MIGRACIONES_DB="$DB_NAME" MIGRACIONES_DIR="$PROJECT_DIR/db/migrations" \
#           migraciones_aplicar || err "fallo al migrar la base"
#
#       Cargada con `source` NO toca las opciones del shell que la carga
#       (nada de `set -e` por sorpresa) y NUNCA llama a `exit` dentro de una
#       funcion: siempre devuelve un codigo de retorno.
#
#    2) Suelta, para probarla:
#
#         bash installer/lib/migraciones.sh estado   --db sistema --dir db/migrations
#         bash installer/lib/migraciones.sh aplicar  --db sistema --dir db/migrations
#
#  CODIGOS DE RETORNO
#    0  todo en orden (incluida la segunda pasada, que no aplica nada)
#    1  una migracion fallo (o no se pudo escribir el registro)
#    2  problema de uso o de entorno (falta mysql, falta la carpeta, sin conexion)
#    3  una migracion ya aplicada cambio de contenido y se aborto por ello
#
#  CREDENCIALES
#    Nunca van en la linea de comandos (se verian en `ps`) ni se escriben en
#    disco en claro ni se imprimen. Se aceptan, por este orden:
#      MIGRACIONES_DEFAULTS_FILE  fichero de opciones de MySQL ya existente
#                                 (ej. /root/.my.cnf), se pasa con
#                                 --defaults-extra-file
#      MIGRACIONES_DB_USER + MIGRACIONES_DB_PASS   la clave viaja por MYSQL_PWD
#                                 solo durante la llamada al cliente
#      nada                       autenticacion del sistema (socket unix como
#                                 root, que es lo que hace hoy install.sh)
#
#  DEPENDENCIAS: bash 4.2+, mysql (o mariadb), sha256sum o md5sum, awk/sed.
# ============================================================================

# ---------------------------------------------------------------------------
# Variables de configuracion (todas se pueden fijar desde fuera)
# ---------------------------------------------------------------------------
MIGRACIONES_DB="${MIGRACIONES_DB:-${DB_NAME:-}}"
MIGRACIONES_DIR="${MIGRACIONES_DIR:-}"
MIGRACIONES_TABLA="${MIGRACIONES_TABLA:-migraciones_aplicadas}"

# Credenciales. Si el instalador ya tiene DB_USER/DB_PASS en el entorno se
# heredan, pero solo si no se dijo otra cosa explicitamente.
MIGRACIONES_DEFAULTS_FILE="${MIGRACIONES_DEFAULTS_FILE:-}"
MIGRACIONES_DB_USER="${MIGRACIONES_DB_USER:-${DB_USER:-}}"
MIGRACIONES_DB_PASS="${MIGRACIONES_DB_PASS:-${DB_PASS:-}}"
MIGRACIONES_DB_HOST="${MIGRACIONES_DB_HOST:-}"
MIGRACIONES_DB_PORT="${MIGRACIONES_DB_PORT:-}"
MIGRACIONES_DB_SOCKET="${MIGRACIONES_DB_SOCKET:-}"

MIGRACIONES_CLIENTE="${MIGRACIONES_CLIENTE:-}"    # se autodetecta: mysql o mariadb
MIGRACIONES_CHARSET="${MIGRACIONES_CHARSET:-utf8mb4}"

# Que hacer cuando una migracion YA APLICADA tiene hoy otro contenido:
#   abortar (por defecto) | avisar
# Ver la nota "SUMA DE VERIFICACION" mas abajo.
MIGRACIONES_SUMA_CAMBIADA="${MIGRACIONES_SUMA_CAMBIADA:-abortar}"

MIGRACIONES_SIMULAR="${MIGRACIONES_SIMULAR:-0}"   # 1 = decir que haria, sin tocar nada

# ---------------------------------------------------------------------------
# SUMA DE VERIFICACION — por que abortar y no solo avisar
#
# Si 003_x.sql ya se aplico en una maquina y despues alguien edito el archivo,
# esa maquina se queda con el esquema viejo y la siguiente que instale tendra
# el nuevo: dos bases distintas con el mismo numero de migracion. Eso es
# exactamente el tipo de divergencia silenciosa que luego aparece como "a mi
# me funciona" o como un cron que falla solo en una maquina.
#
# Por eso el comportamiento por defecto es ABORTAR (codigo 3) antes de aplicar
# nada mas. No se re-aplica sola: re-ejecutar un ALTER editado puede ser
# destructivo y la libreria no puede saberlo.
#
# Que hacer cuando salta:
#   - lo correcto es crear una migracion NUEVA con el cambio, dejar la vieja
#     como esta y volver a ejecutar;
#   - si el cambio es cosmetico (un comentario, un salto de linea) y se ha
#     comprobado a mano que el SQL efectivo es el mismo:
#         migraciones_resellar 003_x.sql
#     que actualiza la suma guardada sin ejecutar nada;
#   - para desbloquear una instalacion a sabiendas, en una sola ejecucion:
#         MIGRACIONES_SUMA_CAMBIADA=avisar migraciones_aplicar
#     (o `--cambios avisar` desde la linea de comandos).
#
# La suma solo se compara en migraciones que acabaron en 'ok'. Una que fallo o
# quedo interrumpida se espera que haya sido corregida, asi que ahi un cambio
# de contenido es lo normal y no se protesta.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Mensajes
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _MIG_V=$'\033[0;32m'; _MIG_A=$'\033[1;33m'; _MIG_R=$'\033[0;31m'; _MIG_N=$'\033[0m'
else
    _MIG_V=''; _MIG_A=''; _MIG_R=''; _MIG_N=''
fi
_mig_log()  { printf '%s[migraciones]%s %s\n' "$_MIG_V" "$_MIG_N" "$*"; }
_mig_warn() { printf '%s[migraciones]%s %s\n' "$_MIG_A" "$_MIG_N" "$*" >&2; }
_mig_err()  { printf '%s[migraciones]%s %s\n' "$_MIG_R" "$_MIG_N" "$*" >&2; }

# ---------------------------------------------------------------------------
# Utilidades internas
# ---------------------------------------------------------------------------

# Escapa una cadena para meterla entre comillas simples en SQL.
# Se dobla la barra invertida y la comilla simple; con eso basta para nombres
# de archivo y textos de error, que es lo unico que insertamos.
_mig_escapar() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\'/\'\'}"
    printf '%s' "$s"
}

# Reloj en milisegundos. Si `date` no soporta %N (BSD y similares) se cae a
# segundos; mejor un numero redondo que ninguno.
_mig_ahora_ms() {
    local ns
    ns="$(date +%s%N 2>/dev/null)" || ns=''
    case "$ns" in
        ''|*[!0-9]*) printf '%s' "$(( $(date +%s) * 1000 ))" ;;
        *)           printf '%s' "$(( ns / 1000000 ))" ;;
    esac
}

# Suma de verificacion de un archivo. Imprime "algoritmo suma".
_mig_suma_archivo() {
    local salida
    if command -v sha256sum >/dev/null 2>&1; then
        salida="$(sha256sum "$1")" || return 1
        printf 'sha256 %s' "${salida%% *}"
    elif command -v md5sum >/dev/null 2>&1; then
        salida="$(md5sum "$1")" || return 1
        printf 'md5 %s' "${salida%% *}"
    else
        return 1
    fi
}

# Localiza el cliente de linea de comandos una sola vez.
_mig_detectar_cliente() {
    if [ -n "$MIGRACIONES_CLIENTE" ]; then return 0; fi
    if command -v mysql >/dev/null 2>&1; then
        MIGRACIONES_CLIENTE="mysql"
    elif command -v mariadb >/dev/null 2>&1; then
        MIGRACIONES_CLIENTE="mariadb"
    else
        return 1
    fi
    return 0
}

# Lanza el cliente con las opciones de conexion. El SQL entra por stdin.
# La contrasena viaja por MYSQL_PWD (solo para este proceso) y nunca como
# argumento: los argumentos se ven en `ps` desde cualquier usuario.
_mig_cliente() {
    local -a opc=()
    # --defaults-extra-file tiene que ir el primero de todos.
    if [ -n "$MIGRACIONES_DEFAULTS_FILE" ]; then
        opc+=( "--defaults-extra-file=$MIGRACIONES_DEFAULTS_FILE" )
    fi
    if [ -n "$MIGRACIONES_DB_HOST" ];   then opc+=( "--host=$MIGRACIONES_DB_HOST" ); fi
    if [ -n "$MIGRACIONES_DB_PORT" ];   then opc+=( "--port=$MIGRACIONES_DB_PORT" ); fi
    if [ -n "$MIGRACIONES_DB_SOCKET" ]; then opc+=( "--socket=$MIGRACIONES_DB_SOCKET" ); fi
    if [ -n "$MIGRACIONES_DB_USER" ];   then opc+=( "--user=$MIGRACIONES_DB_USER" ); fi
    if [ -n "$MIGRACIONES_CHARSET" ];   then opc+=( "--default-character-set=$MIGRACIONES_CHARSET" ); fi
    opc+=( "$@" )
    opc+=( "$MIGRACIONES_DB" )

    if [ -n "$MIGRACIONES_DB_PASS" ]; then
        MYSQL_PWD="$MIGRACIONES_DB_PASS" "$MIGRACIONES_CLIENTE" "${opc[@]}"
    else
        "$MIGRACIONES_CLIENTE" "${opc[@]}"
    fi
}

# Consulta que devuelve filas tabuladas y sin cabecera.
_mig_consulta() { _mig_cliente --batch --skip-column-names --raw; }

# Sentencia sin salida util. Devuelve el codigo del cliente.
_mig_ejecutar_sql() { _mig_cliente --batch >/dev/null; }

# Como identificamos quien aplico la migracion. Sirve para distinguir
# "lo aplico el instalador en la VM" de "lo aplico alguien a mano".
_mig_quien() {
    local u h
    u="$(id -un 2>/dev/null)" || u="?"
    h="$(hostname 2>/dev/null)" || h="?"
    printf '%s@%s' "$u" "$h"
}

# Comprueba que hay con que trabajar. No modifica nada.
# 0 = todo listo, 2 = falta algo.
_mig_comprobar_entorno() {
    if ! _mig_detectar_cliente; then
        _mig_err "no encuentro el cliente mysql/mariadb en el PATH"
        return 2
    fi
    if [ -z "$MIGRACIONES_DB" ]; then
        _mig_err "no se dijo contra que base trabajar (MIGRACIONES_DB o --db)"
        return 2
    fi
    if [ -z "$MIGRACIONES_DIR" ]; then
        _mig_err "no se dijo donde estan las migraciones (MIGRACIONES_DIR o --dir)"
        return 2
    fi
    if [ ! -d "$MIGRACIONES_DIR" ]; then
        _mig_err "la carpeta de migraciones no existe: $MIGRACIONES_DIR"
        return 2
    fi
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v md5sum >/dev/null 2>&1; then
        _mig_err "hace falta sha256sum o md5sum para calcular las sumas"
        return 2
    fi
    # Un SELECT 1 para fallar aqui, con un mensaje claro, y no a mitad del bucle.
    local salida rc=0
    salida="$(printf 'SELECT 1;\n' | _mig_consulta 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        _mig_err "no puedo conectar a la base '$MIGRACIONES_DB' ($(_mig_modo_conexion))"
        _mig_err "respuesta del cliente: $(printf '%s' "$salida" | tr '\n' ' ')"
        return 2
    fi
    return 0
}

# Describe como nos estamos conectando, sin soltar la contrasena.
_mig_modo_conexion() {
    if [ -n "$MIGRACIONES_DEFAULTS_FILE" ]; then
        printf 'fichero de opciones %s' "$MIGRACIONES_DEFAULTS_FILE"
    elif [ -n "$MIGRACIONES_DB_USER" ] && [ -n "$MIGRACIONES_DB_PASS" ]; then
        printf 'usuario %s con contrasena del entorno' "$MIGRACIONES_DB_USER"
    elif [ -n "$MIGRACIONES_DB_USER" ]; then
        printf 'usuario %s sin contrasena' "$MIGRACIONES_DB_USER"
    else
        printf 'autenticacion del sistema (socket)'
    fi
}

# Lista los .sql de la carpeta, por nombre. El orden es el del nombre
# (LC_ALL=C), que es justo para lo que sirve el prefijo 001_, 002_...
_mig_listar_archivos() {
    local f
    for f in "$MIGRACIONES_DIR"/*.sql; do
        if [ -f "$f" ]; then printf '%s\n' "${f##*/}"; fi
    done | LC_ALL=C sort
}

# Carga la tabla de control en memoria (arrays asociativos globales).
# Si la tabla no existe todavia, deja los arrays vacios y devuelve 0: eso es
# una maquina nueva, no un error.
_mig_cargar_registro() {
    unset _MIG_SUMA _MIG_ALGO _MIG_ESTADO _MIG_FECHA _MIG_MS
    declare -gA _MIG_SUMA=() _MIG_ALGO=() _MIG_ESTADO=() _MIG_FECHA=() _MIG_MS=()

    local filas rc=0
    filas="$(printf 'SELECT archivo, suma, algoritmo, estado, aplicada_en, COALESCE(duracion_ms, -1) FROM `%s` ORDER BY archivo;\n' \
        "$MIGRACIONES_TABLA" | _mig_consulta 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then return 0; fi

    local archivo suma algo estado fecha ms
    while IFS=$'\t' read -r archivo suma algo estado fecha ms; do
        if [ -z "$archivo" ]; then continue; fi
        _MIG_SUMA["$archivo"]="$suma"
        _MIG_ALGO["$archivo"]="$algo"
        _MIG_ESTADO["$archivo"]="$estado"
        _MIG_FECHA["$archivo"]="$fecha"
        _MIG_MS["$archivo"]="$ms"
    done <<< "$filas"
    return 0
}

# ---------------------------------------------------------------------------
# API publica
# ---------------------------------------------------------------------------

# migraciones_crear_tabla [db] [dir]
# Crea la tabla de control si falta. Idempotente.
migraciones_crear_tabla() {
    if [ -n "${1:-}" ]; then MIGRACIONES_DB="$1"; fi
    if [ -n "${2:-}" ]; then MIGRACIONES_DIR="$2"; fi
    if ! _mig_detectar_cliente; then
        _mig_err "no encuentro el cliente mysql/mariadb en el PATH"
        return 2
    fi

    local sql rc=0
    sql="$(cat <<SQL
CREATE TABLE IF NOT EXISTS \`${MIGRACIONES_TABLA}\` (
  \`id\`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
  \`archivo\`      VARCHAR(190) NOT NULL COMMENT 'nombre del .sql, sin ruta',
  \`suma\`         VARCHAR(64)  NOT NULL DEFAULT '' COMMENT 'suma del contenido aplicado',
  \`algoritmo\`    VARCHAR(10)  NOT NULL DEFAULT 'sha256',
  \`aplicada_en\`  DATETIME     NOT NULL,
  \`duracion_ms\`  INT UNSIGNED DEFAULT NULL,
  \`estado\`       VARCHAR(20)  NOT NULL DEFAULT 'ok' COMMENT 'ok | fallo | ejecutando | adoptada',
  \`mensaje\`      TEXT         DEFAULT NULL COMMENT 'error de MySQL si fallo',
  \`aplicada_por\` VARCHAR(100) DEFAULT NULL COMMENT 'usuario@maquina',
  PRIMARY KEY (\`id\`),
  UNIQUE KEY \`uk_archivo\` (\`archivo\`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL
)"
    local salida
    salida="$(printf '%s\n' "$sql" | _mig_ejecutar_sql 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        _mig_err "no pude crear la tabla de control \`$MIGRACIONES_TABLA\`:"
        _mig_err "$(printf '%s' "$salida" | grep -v -E '^Warning:' | tr '\n' ' ')"
        return 1
    fi
    return 0
}

# Escribe (o pisa) la fila de una migracion. Uso interno, pero publica porque
# migraciones_adoptar y migraciones_resellar la reutilizan.
# $1 archivo  $2 algoritmo  $3 suma  $4 estado  $5 duracion_ms  $6 mensaje
migraciones_registrar() {
    local archivo="$1" algo="$2" suma="$3" estado="$4" ms="${5:-0}" mensaje="${6:-}"
    local rc=0 salida

    # El mensaje se guarda en una sola linea y recortado: la tabla es para
    # enterarse de un vistazo, el detalle completo esta en la salida del
    # instalador.
    mensaje="$(printf '%s' "$mensaje" | tr -d '\r' | tr '\n' '|' | cut -c1-900)"

    salida="$(printf "INSERT INTO \`%s\` (archivo, suma, algoritmo, aplicada_en, duracion_ms, estado, mensaje, aplicada_por)
VALUES ('%s', '%s', '%s', NOW(), %s, '%s', %s, '%s')
ON DUPLICATE KEY UPDATE
  suma=VALUES(suma), algoritmo=VALUES(algoritmo), aplicada_en=VALUES(aplicada_en),
  duracion_ms=VALUES(duracion_ms), estado=VALUES(estado), mensaje=VALUES(mensaje),
  aplicada_por=VALUES(aplicada_por);\n" \
        "$MIGRACIONES_TABLA" \
        "$(_mig_escapar "$archivo")" \
        "$(_mig_escapar "$suma")" \
        "$(_mig_escapar "$algo")" \
        "$ms" \
        "$(_mig_escapar "$estado")" \
        "$(if [ -n "$mensaje" ]; then printf "'%s'" "$(_mig_escapar "$mensaje")"; else printf 'NULL'; fi)" \
        "$(_mig_escapar "$(_mig_quien)")" \
        | _mig_ejecutar_sql 2>&1)" || rc=$?

    if [ "$rc" -ne 0 ]; then
        _mig_err "no pude registrar '$archivo' en \`$MIGRACIONES_TABLA\`:"
        _mig_err "$(printf '%s' "$salida" | grep -v -E '^Warning:' | tr '\n' ' ')"
        return 1
    fi
    return 0
}

# migraciones_aplicar [db] [dir]
# Aplica en orden las que faltan. Para en la primera que falle.
migraciones_aplicar() {
    if [ -n "${1:-}" ]; then MIGRACIONES_DB="$1"; fi
    if [ -n "${2:-}" ]; then MIGRACIONES_DIR="$2"; fi

    local rc=0
    _mig_comprobar_entorno || return $?

    if [ "$MIGRACIONES_SIMULAR" != "1" ]; then
        migraciones_crear_tabla || return $?
    fi
    _mig_cargar_registro

    local archivos
    archivos="$(_mig_listar_archivos)"
    if [ -z "$archivos" ]; then
        _mig_warn "no hay ningun .sql en $MIGRACIONES_DIR; nada que aplicar"
        return 0
    fi

    _mig_log "base '$MIGRACIONES_DB' via $(_mig_modo_conexion)"
    _mig_log "migraciones en $MIGRACIONES_DIR"
    if [ "$MIGRACIONES_SIMULAR" = "1" ]; then
        _mig_warn "modo simulacion: no se va a aplicar ni registrar nada"
    fi

    local aplicadas=0 saltadas=0 archivo ruta algo suma
    while IFS= read -r archivo; do
        if [ -z "$archivo" ]; then continue; fi
        ruta="$MIGRACIONES_DIR/$archivo"

        local par
        par="$(_mig_suma_archivo "$ruta")" || {
            _mig_err "no pude calcular la suma de $archivo"
            return 1
        }
        algo="${par%% *}"
        suma="${par##* }"

        local estado_prev="${_MIG_ESTADO[$archivo]:-}"

        case "$estado_prev" in
            ok|adoptada)
                # Ya aplicada: comprobar que el contenido sigue siendo el mismo.
                local algo_prev="${_MIG_ALGO[$archivo]:-}" suma_prev="${_MIG_SUMA[$archivo]:-}"
                if [ "$estado_prev" = "adoptada" ] && [ -z "$suma_prev" ]; then
                    : # adoptada sin suma (base heredada): no hay con que comparar
                elif [ -n "$algo_prev" ] && [ "$algo_prev" != "$algo" ]; then
                    _mig_warn "$archivo: se guardo con $algo_prev y aqui solo hay $algo; no puedo comparar"
                elif [ "$suma_prev" != "$suma" ]; then
                    if [ "$MIGRACIONES_SUMA_CAMBIADA" = "avisar" ]; then
                        _mig_warn "$archivo CAMBIO despues de aplicarse (suma distinta). Se continua porque"
                        _mig_warn "  MIGRACIONES_SUMA_CAMBIADA=avisar, pero esta maquina NO tiene el contenido actual."
                    else
                        _mig_err "$archivo CAMBIO despues de haberse aplicado el ${_MIG_FECHA[$archivo]:-?}."
                        _mig_err "  guardada: $algo_prev:$suma_prev"
                        _mig_err "  en disco: $algo:$suma"
                        _mig_err "  Esta maquina tiene el esquema VIEJO y otra con el mismo numero puede tener otro."
                        _mig_err "  Arreglo correcto: crear una migracion nueva con el cambio."
                        _mig_err "  Si el cambio no afecta al SQL: migraciones_resellar '$archivo'"
                        _mig_err "  Para seguir a sabiendas: MIGRACIONES_SUMA_CAMBIADA=avisar"
                        return 3
                    fi
                fi
                saltadas=$((saltadas + 1))
                continue
                ;;
            ejecutando)
                _mig_warn "$archivo quedo marcada como 'ejecutando' el ${_MIG_FECHA[$archivo]:-?}:"
                _mig_warn "  la ejecucion anterior se corto a mitad. Se reintenta; si el SQL no es"
                _mig_warn "  repetible puede fallar y habra que revisar la tabla a mano."
                ;;
            fallo)
                _mig_warn "$archivo fallo el ${_MIG_FECHA[$archivo]:-?}; se reintenta."
                ;;
        esac

        if [ "$MIGRACIONES_SIMULAR" = "1" ]; then
            _mig_log "PENDIENTE (simulacion) $archivo"
            aplicadas=$((aplicadas + 1))
            continue
        fi

        # Dejar constancia ANTES de ejecutar. Si el proceso muere a mitad
        # (ssh cortado, OOM, kill) la fila queda en 'ejecutando' y la proxima
        # pasada lo dice, en vez de parecer que nunca se intento.
        migraciones_registrar "$archivo" "$algo" "$suma" "ejecutando" 0 "" || return 1

        local t0 t1 ms salida rc_mig=0
        t0="$(_mig_ahora_ms)"
        salida="$(_mig_cliente < "$ruta" 2>&1)" || rc_mig=$?
        t1="$(_mig_ahora_ms)"
        ms=$(( t1 - t0 ))
        if [ "$ms" -lt 0 ]; then ms=0; fi

        # El cliente escupe "Warning: ..." por cosas inocuas; el que manda es
        # el codigo de salida, no la presencia de texto.
        local limpio
        limpio="$(printf '%s' "$salida" | grep -v -E '^Warning:' || true)"

        if [ "$rc_mig" -ne 0 ]; then
            migraciones_registrar "$archivo" "$algo" "$suma" "fallo" "$ms" "$limpio" || true
            _mig_err "FALLO $archivo tras ${ms} ms (codigo $rc_mig). Error de MySQL:"
            printf '%s\n' "$limpio" | sed 's/^/    /' >&2
            _mig_err "Se detiene aqui: la base queda sin las migraciones posteriores."
            _mig_err "Corrige el .sql, vuelve a lanzar y continuara por esta misma."
            return 1
        fi

        migraciones_registrar "$archivo" "$algo" "$suma" "ok" "$ms" "" || return 1
        _mig_log "aplicada $archivo (${ms} ms)"
        aplicadas=$((aplicadas + 1))

        if [ -n "$limpio" ]; then
            printf '%s\n' "$limpio" | sed 's/^/    /'
        fi
    done <<< "$archivos"

    if [ "$MIGRACIONES_SIMULAR" = "1" ]; then
        _mig_log "simulacion: $aplicadas se aplicarian, $saltadas ya estaban"
    else
        _mig_log "listo: $aplicadas aplicadas, $saltadas ya estaban al dia"
    fi
    return $rc
}

# migraciones_estado [db] [dir]
# Tabla legible de que hay, que se aplico y que falta.
migraciones_estado() {
    if [ -n "${1:-}" ]; then MIGRACIONES_DB="$1"; fi
    if [ -n "${2:-}" ]; then MIGRACIONES_DIR="$2"; fi
    _mig_comprobar_entorno || return $?
    _mig_cargar_registro

    local archivos
    archivos="$(_mig_listar_archivos)"

    printf '\n  Base: %s   Carpeta: %s\n' "$MIGRACIONES_DB" "$MIGRACIONES_DIR"
    printf '  %-12s %-42s %-19s %8s\n' "ESTADO" "ARCHIVO" "APLICADA EN" "MS"
    printf '  %-12s %-42s %-19s %8s\n' "------------" "------------------------------------------" "-------------------" "--------"

    local archivo pendientes=0 ok=0 problemas=0 par algo suma estado_prev etiqueta fecha ms
    while IFS= read -r archivo; do
        if [ -z "$archivo" ]; then continue; fi
        estado_prev="${_MIG_ESTADO[$archivo]:-}"
        fecha="${_MIG_FECHA[$archivo]:-}"
        ms="${_MIG_MS[$archivo]:--1}"
        if [ "$ms" = "-1" ] || [ "$ms" = "NULL" ]; then ms="-"; fi

        case "$estado_prev" in
            ok|adoptada)
                par="$(_mig_suma_archivo "$MIGRACIONES_DIR/$archivo")" || par="? ?"
                algo="${par%% *}"; suma="${par##* }"
                if [ -n "${_MIG_SUMA[$archivo]:-}" ] && [ "${_MIG_ALGO[$archivo]:-}" = "$algo" ] \
                   && [ "${_MIG_SUMA[$archivo]}" != "$suma" ]; then
                    etiqueta="CAMBIADA"
                    problemas=$((problemas + 1))
                else
                    etiqueta="$estado_prev"
                    ok=$((ok + 1))
                fi
                ;;
            ejecutando) etiqueta="INTERRUMPIDA"; problemas=$((problemas + 1)) ;;
            fallo)      etiqueta="FALLO";        problemas=$((problemas + 1)) ;;
            *)          etiqueta="pendiente";    fecha="-"; ms="-"; pendientes=$((pendientes + 1)) ;;
        esac
        printf '  %-12s %-42s %-19s %8s\n' "$etiqueta" "$archivo" "${fecha:--}" "$ms"
    done <<< "$archivos"

    # Filas registradas cuyo archivo ya no esta: alguien borro o renombro un
    # .sql. No es un fallo, pero conviene saberlo.
    local huerfanas=0 reg
    for reg in "${!_MIG_ESTADO[@]}"; do
        if [ ! -f "$MIGRACIONES_DIR/$reg" ]; then
            printf '  %-12s %-42s %-19s %8s\n' "HUERFANA" "$reg" "${_MIG_FECHA[$reg]:--}" "-"
            huerfanas=$((huerfanas + 1))
        fi
    done

    printf '\n  %s al dia, %s pendientes, %s con problema, %s huerfanas\n\n' \
        "$ok" "$pendientes" "$problemas" "$huerfanas"

    if [ "$problemas" -gt 0 ]; then return 1; fi
    return 0
}

# migraciones_pendientes [db] [dir]
# Solo los nombres pendientes, uno por linea. Pensada para usar desde otros
# scripts (`if [ -n "$(migraciones_pendientes)" ]; then ...`).
migraciones_pendientes() {
    if [ -n "${1:-}" ]; then MIGRACIONES_DB="$1"; fi
    if [ -n "${2:-}" ]; then MIGRACIONES_DIR="$2"; fi
    _mig_comprobar_entorno || return $?
    _mig_cargar_registro
    local archivo
    while IFS= read -r archivo; do
        if [ -z "$archivo" ]; then continue; fi
        case "${_MIG_ESTADO[$archivo]:-}" in
            ok|adoptada) ;;
            *) printf '%s\n' "$archivo" ;;
        esac
    done <<< "$(_mig_listar_archivos)"
    return 0
}

# migraciones_adoptar [db] [dir]
# Marca como aplicadas TODAS las migraciones presentes, SIN ejecutarlas.
# Para maquinas que ya venian funcionando antes de existir esta tabla y cuyo
# esquema ya esta al dia: sin esto, la primera pasada intentaria aplicarlas
# todas otra vez. Se guarda con estado 'adoptada' para que se distinga de lo
# que esta libreria aplico de verdad.
migraciones_adoptar() {
    if [ -n "${1:-}" ]; then MIGRACIONES_DB="$1"; fi
    if [ -n "${2:-}" ]; then MIGRACIONES_DIR="$2"; fi
    _mig_comprobar_entorno || return $?
    migraciones_crear_tabla || return $?
    _mig_cargar_registro

    local archivo par algo suma n=0
    while IFS= read -r archivo; do
        if [ -z "$archivo" ]; then continue; fi
        case "${_MIG_ESTADO[$archivo]:-}" in
            ok|adoptada) continue ;;
        esac
        par="$(_mig_suma_archivo "$MIGRACIONES_DIR/$archivo")" || return 1
        algo="${par%% *}"; suma="${par##* }"
        migraciones_registrar "$archivo" "$algo" "$suma" "adoptada" 0 \
            "marcada como ya presente sin ejecutarla" || return 1
        _mig_log "adoptada (no ejecutada) $archivo"
        n=$((n + 1))
    done <<< "$(_mig_listar_archivos)"
    _mig_log "$n migraciones dadas por aplicadas sin ejecutar"
    return 0
}

# migraciones_resellar <archivo> [db] [dir]
# Actualiza la suma guardada de una migracion ya aplicada, sin ejecutarla.
# Solo despues de comprobar a mano que el cambio en el archivo no altera el
# SQL que se ejecuto (un comentario, un espacio). Ver la nota de arriba.
migraciones_resellar() {
    local archivo="${1:-}"
    if [ -z "$archivo" ]; then
        _mig_err "uso: migraciones_resellar <archivo.sql>"
        return 2
    fi
    if [ -n "${2:-}" ]; then MIGRACIONES_DB="$2"; fi
    if [ -n "${3:-}" ]; then MIGRACIONES_DIR="$3"; fi
    _mig_comprobar_entorno || return $?

    archivo="${archivo##*/}"
    if [ ! -f "$MIGRACIONES_DIR/$archivo" ]; then
        _mig_err "no existe $MIGRACIONES_DIR/$archivo"
        return 2
    fi
    _mig_cargar_registro
    case "${_MIG_ESTADO[$archivo]:-}" in
        ok|adoptada) ;;
        *) _mig_err "$archivo no consta como aplicada; no hay nada que resellar"; return 2 ;;
    esac

    local par algo suma
    par="$(_mig_suma_archivo "$MIGRACIONES_DIR/$archivo")" || return 1
    algo="${par%% *}"; suma="${par##* }"

    local rc=0 salida
    salida="$(printf "UPDATE \`%s\` SET suma='%s', algoritmo='%s', mensaje=CONCAT(COALESCE(mensaje,''), ' | resellada %s por %s') WHERE archivo='%s';\n" \
        "$MIGRACIONES_TABLA" "$(_mig_escapar "$suma")" "$(_mig_escapar "$algo")" \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$(_mig_escapar "$(_mig_quien)")" \
        "$(_mig_escapar "$archivo")" | _mig_ejecutar_sql 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        _mig_err "no pude resellar $archivo: $(printf '%s' "$salida" | tr '\n' ' ')"
        return 1
    fi
    _mig_log "resellada $archivo con $algo:$suma (no se ejecuto nada)"
    return 0
}

# ---------------------------------------------------------------------------
# Modo suelto (solo cuando se ejecuta este archivo, no cuando se hace source)
# ---------------------------------------------------------------------------
_mig_ayuda() {
    cat <<'FIN'
Uso: bash migraciones.sh <orden> [opciones]

Ordenes:
  aplicar              aplica lo que falte, en orden, parando en el primer fallo
  estado               tabla con que hay aplicado y que falta
  pendientes           solo los nombres pendientes, uno por linea
  adoptar              marca las existentes como aplicadas SIN ejecutarlas
                       (base que ya estaba al dia antes de existir el registro)
  resellar <archivo>   actualiza la suma guardada de una ya aplicada, sin ejecutar

Opciones:
  --db <nombre>          base de datos               (o MIGRACIONES_DB / DB_NAME)
  --dir <ruta>           carpeta con los .sql         (o MIGRACIONES_DIR)
  --tabla <nombre>       tabla de control             (def. migraciones_aplicadas)
  --defaults-file <f>    fichero de opciones de MySQL (ej. /root/.my.cnf)
  --user <usuario>       usuario                      (la clave, por MIGRACIONES_DB_PASS)
  --host <host> --port <n> --socket <ruta>
  --cambios abortar|avisar   que hacer si una ya aplicada cambio (def. abortar)
  --simular              dice que haria, sin aplicar ni registrar nada
  -h, --help

Codigos: 0 bien | 1 fallo de migracion | 2 uso/entorno | 3 suma cambiada
La contrasena nunca se pasa por la linea de comandos: usa MIGRACIONES_DB_PASS
o un fichero de opciones.
FIN
}

_mig_main() {
    local orden="${1:-}"
    if [ -z "$orden" ]; then _mig_ayuda; return 2; fi
    shift || true

    local extra=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --db)            MIGRACIONES_DB="${2:-}"; shift 2 ;;
            --dir)           MIGRACIONES_DIR="${2:-}"; shift 2 ;;
            --tabla)         MIGRACIONES_TABLA="${2:-}"; shift 2 ;;
            --defaults-file) MIGRACIONES_DEFAULTS_FILE="${2:-}"; shift 2 ;;
            --user)          MIGRACIONES_DB_USER="${2:-}"; shift 2 ;;
            --host)          MIGRACIONES_DB_HOST="${2:-}"; shift 2 ;;
            --port)          MIGRACIONES_DB_PORT="${2:-}"; shift 2 ;;
            --socket)        MIGRACIONES_DB_SOCKET="${2:-}"; shift 2 ;;
            --cambios)       MIGRACIONES_SUMA_CAMBIADA="${2:-}"; shift 2 ;;
            --simular)       MIGRACIONES_SIMULAR=1; shift ;;
            -h|--help)       _mig_ayuda; return 0 ;;
            --*)             _mig_err "opcion desconocida: $1"; return 2 ;;
            *)               extra="$1"; shift ;;
        esac
    done

    case "$orden" in
        aplicar)    migraciones_aplicar ;;
        estado)     migraciones_estado ;;
        pendientes) migraciones_pendientes ;;
        adoptar)    migraciones_adoptar ;;
        resellar)   migraciones_resellar "$extra" ;;
        -h|--help)  _mig_ayuda ;;
        *)          _mig_err "orden desconocida: $orden"; _mig_ayuda; return 2 ;;
    esac
}

# `source` no debe imponer opciones al shell que carga la libreria; ejecutada
# suelta si queremos el modo estricto del repositorio.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    set -Eeuo pipefail
    _mig_main "$@"
    exit $?
fi
