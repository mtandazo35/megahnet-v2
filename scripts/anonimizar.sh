#!/usr/bin/env bash
# anonimizar.sh — convierte un volcado de MariaDB de produccion en una copia SIN datos
# personales, lista para cargar en la maquina de pruebas del laboratorio.
#
# Uso:
#   bash scripts/anonimizar.sh respaldo-produccion.sql.gz salida-anonimizada.sql.gz
#   bash scripts/anonimizar.sh respaldo.sql              salida.sql
#
# El archivo de ENTRADA no se toca nunca: se lee, se carga en una base TEMPORAL local,
# se anonimiza ahi, se vuelve a volcar y la base temporal se borra SIEMPRE, tambien si
# el script falla a mitad (trap EXIT). No se conecta a ningun servidor remoto.
#
# Conexion a la base local (variables de entorno, todas opcionales):
#   DB_HOST     (localhost)   DB_PUERTO (3306)   DB_SOCKET (vacio)
#   DB_USUARIO  (root)        DB_CLAVE  (vacia)
#   SAL_ANON    sal con la que se derivan los datos falsos. Si no se pasa se genera
#               al azar en cada ejecucion. Con la misma sal y la misma entrada la
#               salida es la misma: util para comparar dos corridas.
#
# CLAVE DE LABORATORIO (esto es lo unico que se documenta aqui a proposito):
#   todos los registros de `usuarios` quedan con la contrasena  laboratorio
#   hash bcrypt fijo: $2y$10$hGq8qxyd6AbBYYody0CInOF7SQ81e47/9X2JzT0ojnrvfIXFKGIW6
#   El sistema valida con password_verify() (bcrypt), asi que el hash entra tal cual.
#   El script NO imprime claves en pantalla en ningun momento.
#
# QUE SE CONSERVA (es el motivo de usar una copia real y no datos inventados):
#   - El volumen: ningun DELETE, ningun INSERT. Solo UPDATE.
#   - Los casos sucios: un correo NULL sigue NULL, uno vacio sigue vacio, y uno mal
#     escrito queda mal escrito DEL MISMO MODO (sin arroba, con espacios, dominio sin
#     punto, un RUC metido en el campo correo). Son los que rompen el sistema.
#   - Las relaciones: no se toca ningun id ni ninguna clave foranea.
#   - Importes, fechas, estados, secuenciales y claves de acceso del SRI: intactos.
#
# COHERENCIA. Todo valor falso sale de SHA2(sal + valor original), asi que dos celdas
# con el mismo valor real acaban con el mismo valor falso aunque esten en tablas
# distintas. `datos_cabecera_electronica` y `nota_credito_cabecera` son FOTOS del
# cliente al emitir, y ademas guardan el nombre recortado a 75/100 caracteres; por eso
# su columna de nombre se resuelve por `id_cliente` contra una copia de `clientes`
# tomada antes de tocar nada, no por el texto recortado.
#
# DECISIONES QUE CONVIENE CONOCER (el porque, no el que):
#   - `clientes`.`identidad` NO se toca: no es un dato personal, es el TIPO de
#     documento ('CEDULA'/'RUC') y la facturacion electronica decide con el (ver
#     controllers/Automaticas.php). El numero esta en `num_identidad`, y ese si se
#     sustituye.
#   - Los nombres falsos llevan un sufijo numerico porque megahnet casa clientes POR
#     NOMBRE en varios sitios: si dos clientes distintos recibieran el mismo nombre
#     falso, el laboratorio mentiria.
#   - Las cedulas/RUC falsos mantienen la longitud y el formato (10 / 13 con '001'),
#     pero NO cumplen el digito verificador ecuatoriano.
#   - Las IP se reescriben a 10.77.x.y conservando los dos ultimos octetos, y el mismo
#     cambio se aplica a los pools (`ip`, `ip_anuladas`) y a los equipos (`mikrotik`,
#     `repetidoras`): asi el laboratorio sigue siendo coherente consigo mismo y, de
#     paso, no puede alcanzar un equipo real de produccion.
#   - Las credenciales de los MikroTik se invalidan. En produccion van cifradas con la
#     KEY de la aplicacion; aqui se deja un texto que no descifra, de modo que el
#     laboratorio falla al conectar en vez de entrar a un router de verdad.
#   - La identidad de la empresa se cambia en `configuracion` (de ahi salen los
#     documentos nuevos), pero NO en las fotos historicas (`ruc_empresa`,
#     `razon_social`, `direccion_matriz` de facturas ya emitidas): esos campos cuadran
#     con la clave de acceso del SRI, que es un secuencial y no se toca.
#
#   - Ademas de las tablas del encargo se tratan `retencion`, `nota_credito_cabecera`
#     y `proveedor`: son el mismo dato personal en otra tabla, y dejarlo ahi haria
#     falso el "esta copia no lleva datos de clientes".
#   - Cualquier columna de texto llamada correo/mail/telefono/celular/whatsapp en
#     CUALQUIER tabla pasa por las mismas reglas, aunque no estuviera en el plan, y se
#     lista aparte en el resumen.
#
# Lo que el script NO decide por su cuenta: cualquier otra columna que huela a dato
# personal o a credencial se LISTA al final con su recuento, sin tocarla, para que lo
# mire una persona.
#
# PROBARLO SIN UN VOLCADO REAL. En la maquina de pruebas:
#   mysql -e "CREATE DATABASE ensayo"
#   mysql ensayo < ../megahnet/db/schema.sql
#   mysql ensayo -e "INSERT INTO clientes (identidad,num_identidad,nombre,telefono,correo,direccion)
#     VALUES ('CEDULA','1103456789','JUAN PEREZ','0991234567','juan@gmail.com','Calle Real 123'),
#            ('CEDULA','1104567890','ANA LOPEZ', NULL,        NULL,            'Sin direccion'),
#            ('CEDULA','1105678901','LUIS VEGA','099',        '',              'Barrio Centro'),
#            ('RUC',   '1106789012001','COMERCIAL SA','0987654321','klopezb16@gmailcom','Av. 1'),
#            ('CEDULA','1107890123','ROSA DIAZ','0998887766','1103456789001','Km 2')"
#   mysqldump ensayo | gzip > /root/ensayo.sql.gz
#   bash scripts/anonimizar.sh /root/ensayo.sql.gz /root/ensayo-anon.sql.gz
# El resumen debe decir que los correos vacios, nulos, sin arroba y con dominio sin
# punto siguen siendo los mismos de antes.

set -Eeuo pipefail

# ---------------------------------------------------------------- utilidades de salida
msg()    { printf '%s\n' "$*"; }
titulo() { printf '\n== %s\n' "$*"; }
aviso()  { printf 'AVISO  %s\n' "$*"; AVISOS=$((AVISOS + 1)); }
morir()  { printf 'ERROR  %s\n' "$*" >&2; exit 1; }
AVISOS=0

# ---------------------------------------------------------------- argumentos
ENTRADA="${1:-}"
SALIDA="${2:-}"

if [[ -z "$ENTRADA" || -z "$SALIDA" ]]; then
    morir "uso: bash scripts/anonimizar.sh <volcado-entrada.sql[.gz]> <volcado-salida.sql[.gz]>"
fi
[[ -f "$ENTRADA" ]] || morir "no existe el volcado de entrada: $ENTRADA"
[[ -r "$ENTRADA" ]] || morir "no se puede leer el volcado de entrada: $ENTRADA"
[[ -s "$ENTRADA" ]] || morir "el volcado de entrada esta vacio: $ENTRADA"

# La entrada es sagrada: si la salida apuntase al mismo archivo lo destruiriamos.
if [[ -e "$SALIDA" ]] && [[ "$ENTRADA" -ef "$SALIDA" ]]; then
    morir "la salida apunta al mismo archivo que la entrada; elige otro nombre"
fi
DIR_SALIDA="$(dirname -- "$SALIDA")"
[[ -d "$DIR_SALIDA" ]] || morir "no existe el directorio de salida: $DIR_SALIDA"
[[ -w "$DIR_SALIDA" ]] || morir "no se puede escribir en el directorio de salida: $DIR_SALIDA"

# ---------------------------------------------------------------- requisitos
for programa in mysql mysqldump awk sed od; do
    command -v "$programa" >/dev/null 2>&1 || morir "falta el programa '$programa'"
done

# gzip solo hace falta si entra o sale comprimido; se comprueba abajo, cuando se sabe.
ENTRADA_GZ=0
if [[ "$(od -An -N2 -tx1 < "$ENTRADA" | tr -d ' \n')" == "1f8b" ]]; then
    ENTRADA_GZ=1   # por los bytes magicos, no por la extension: hay respaldos sin .gz
fi
SALIDA_GZ=0
[[ "$SALIDA" == *.gz ]] && SALIDA_GZ=1
if [[ "$ENTRADA_GZ" -eq 1 || "$SALIDA_GZ" -eq 1 ]]; then
    command -v gzip >/dev/null 2>&1 || morir "falta el programa 'gzip'"
fi

# ------------------------------------------------- cerrojo: solo base de datos local
# Este script CREA una base temporal en el servidor al que apunte. La primera regla
# del laboratorio es que produccion no se toca desde aqui, asi que por defecto solo
# se permite trabajar contra la base local. Para un caso justificado:
#     ANON_PERMITIR_REMOTO=1 bash scripts/anonimizar.sh entrada.sql.gz salida.sql.gz
case "${DB_HOST:-localhost}" in
    localhost|127.0.0.1|::1|"") ;;
    *)
        if [[ "${ANON_PERMITIR_REMOTO:-0}" != "1" ]]; then
            morir "DB_HOST apunta a '$DB_HOST' y este script CREA una base temporal alli.
       Produccion no se toca desde el laboratorio. Si de verdad lo necesitas:
       ANON_PERMITIR_REMOTO=1 $0 ..."
        fi
        aviso "trabajando contra un servidor remoto ($DB_HOST) por peticion explicita"
        ;;
esac

# ---------------------------------------------------------------- entorno de trabajo
TRABAJO="$(mktemp -d)"
CNF="$TRABAJO/cliente.cnf"
SQL="$TRABAJO/anonimizar.sql"
BASE="anon_$(date +%Y%m%d%H%M%S)_$$"
BASE_CREADA=0

limpiar() {
    local codigo=$?
    if [[ "$BASE_CREADA" -eq 1 ]]; then
        if ! mysql --defaults-file="$CNF" -e "DROP DATABASE IF EXISTS \`$BASE\`;" >/dev/null 2>&1; then
            printf 'AVISO  no se pudo borrar la base temporal %s; borrala a mano\n' "$BASE" >&2
        fi
    fi
    [[ -d "$TRABAJO" ]] && rm -rf "$TRABAJO"
    return $codigo
}
trap limpiar EXIT

# El fichero de credenciales evita que la clave aparezca en la linea de comandos
# (y por tanto en `ps`). umask 077 antes de crearlo, no chmod despues.
(
    umask 077
    {
        printf '[client]\n'
        printf 'user=%s\n' "${DB_USUARIO:-root}"
        [[ -n "${DB_CLAVE:-}" ]]  && printf 'password=%s\n' "$DB_CLAVE"
        printf 'host=%s\n' "${DB_HOST:-localhost}"
        printf 'port=%s\n' "${DB_PUERTO:-3306}"
        [[ -n "${DB_SOCKET:-}" ]] && printf 'socket=%s\n' "$DB_SOCKET"
        printf 'default-character-set=utf8mb4\n'
    } > "$CNF"
)

# Sal aleatoria por ejecucion: sin ella no se puede volver del dato falso al real.
# Se puede fijar con SAL_ANON para que dos corridas den exactamente lo mismo.
if [[ -n "${SAL_ANON:-}" ]]; then
    SAL="$SAL_ANON"
elif [[ -r /dev/urandom ]]; then
    SAL="$(od -An -N24 -tx1 < /dev/urandom | tr -d ' \n')"
else
    SAL="$(date +%s%N)-$$-${RANDOM}${RANDOM}"
fi
SAL="${SAL//\'/}"   # la sal entra en un literal SQL; fuera comillas

# ---------------------------------------------------------------- helpers de base
sqlv()  { mysql --defaults-file="$CNF" --batch --skip-column-names "$BASE" -e "$1" < /dev/null; }

titulo "MEGAHNET LAB — anonimizar volcado"
msg "  entrada : $ENTRADA"
msg "  salida  : $SALIDA"
msg "  base temporal: $BASE (se borra al terminar, pase lo que pase)"

mysql --defaults-file="$CNF" -e 'SELECT 1' >/dev/null 2>&1 \
    || morir "no se pudo conectar a MariaDB/MySQL local; revisa DB_USUARIO/DB_CLAVE/DB_HOST"

mysql --defaults-file="$CNF" -e \
    "CREATE DATABASE \`$BASE\` DEFAULT CHARACTER SET utf8mb4;" >/dev/null \
    || morir "no se pudo crear la base temporal (hace falta permiso CREATE)"
BASE_CREADA=1

# ---------------------------------------------------------------- carga del volcado
# Un volcado hecho con --databases trae CREATE DATABASE y USE: si los dejamos pasar,
# el contenido acabaria en la base de produccion de ESTA maquina en vez de en la
# temporal. Se descartan y se avisa.
filtro_volcado() {
    awk '
        /^USE `/              { n++; next }
        /^CREATE DATABASE/    { n++; next }
        /^\/\*!40000 DROP DATABASE/ { n++; next }
        { print }
        END { if (n > 0) printf("AVISO  se descartaron %d lineas USE/CREATE DATABASE: todo se carga en la base temporal\n", n) > "/dev/stderr" }
    '
}

titulo "Cargando el volcado en la base temporal"
if [[ "$ENTRADA_GZ" -eq 1 ]]; then
    gzip -dc -- "$ENTRADA" | filtro_volcado | mysql --defaults-file="$CNF" "$BASE"
else
    filtro_volcado < "$ENTRADA" | mysql --defaults-file="$CNF" "$BASE"
fi
N_TABLAS="$(sqlv "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$BASE';")"
[[ "$N_TABLAS" -gt 0 ]] || morir "el volcado no creo ninguna tabla; revisa que sea un mysqldump valido"
msg "  cargado: $N_TABLAS tablas"

# Indice de columnas en memoria: una sola consulta en vez de un SHOW COLUMNS por campo.
# El esquema del servidor manda; lo que no exista se salta sin romper.
sqlv "SELECT CONCAT(TABLE_NAME,'.',COLUMN_NAME) FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA='$BASE';" > "$TRABAJO/columnas.txt"
hay() { grep -qxF "$1" "$TRABAJO/columnas.txt"; }

# Recuento de filas por tabla ANTES, para demostrar al final que no se perdio ninguna.
sqlv "SELECT TABLE_NAME FROM information_schema.TABLES
      WHERE TABLE_SCHEMA='$BASE' AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME;" \
      > "$TRABAJO/tablas.txt"
contar_filas() {
    local destino="$1" t
    : > "$destino"
    while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        printf '%s\t%s\n' "$t" "$(sqlv "SELECT COUNT(*) FROM \`$t\`;")" >> "$destino"
    done < "$TRABAJO/tablas.txt"
}
contar_filas "$TRABAJO/filas_antes.txt"

# ---------------------------------------------------------------- censo de casos sucios
# Se mide antes y despues. Si un recuento cambia es que el anonimizado se comio un caso
# raro, que es justo lo que no puede pasar.
censo_correo() {
    local t="$1" c="$2"
    hay "$t.$c" || return 0
    sqlv "SELECT CONCAT_WS('|',
            COUNT(*),
            COALESCE(SUM(\`$c\` IS NULL),0),
            COALESCE(SUM(\`$c\` IS NOT NULL AND TRIM(\`$c\`)=''),0),
            COALESCE(SUM(\`$c\` IS NOT NULL AND TRIM(\`$c\`)<>'' AND \`$c\` NOT LIKE '%@%'),0),
            COALESCE(SUM(\`$c\` LIKE '% %'),0),
            COALESCE(SUM(\`$c\` LIKE '%@%' AND SUBSTRING_INDEX(\`$c\`,'@',-1) NOT LIKE '%.%'),0),
            COALESCE(SUM(\`$c\` REGEXP '^[0-9]+\$'),0)
          ) FROM \`$t\`;"
}
censo_telefono() {
    local t="$1" c="$2"
    hay "$t.$c" || return 0
    sqlv "SELECT CONCAT_WS('|',
            COUNT(*),
            COALESCE(SUM(\`$c\` IS NULL),0),
            COALESCE(SUM(\`$c\` IS NOT NULL AND TRIM(\`$c\`)=''),0),
            COALESCE(SUM(\`$c\` IS NOT NULL AND TRIM(\`$c\`)<>'' AND \`$c\` NOT REGEXP '^[0-9]+\$'),0),
            COALESCE(SUM(\`$c\` IS NOT NULL AND TRIM(\`$c\`)<>'' AND CHAR_LENGTH(\`$c\`)<>10),0)
          ) FROM \`$t\`;"
}

CORREOS_VIGILADOS=(
    "clientes.correo"
    "datos_cabecera_electronica.correo"
    "usuarios.correo"
    "proveedor.correo"
)
TELEFONOS_VIGILADOS=(
    "clientes.telefono"
    "datos_cabecera_electronica.telefono"
    "usuarios.telefono"
)
declare -A CENSO_ANTES=()
for ref in "${CORREOS_VIGILADOS[@]}"; do
    CENSO_ANTES[$ref]="$(censo_correo "${ref%%.*}" "${ref#*.}")"
done
for ref in "${TELEFONOS_VIGILADOS[@]}"; do
    CENSO_ANTES[$ref]="$(censo_telefono "${ref%%.*}" "${ref#*.}")"
done
IP_DISTINTAS_ANTES=""
if hay "contratos.ip_usuario"; then
    IP_DISTINTAS_ANTES="$(sqlv "SELECT COUNT(DISTINCT \`ip_usuario\`) FROM \`contratos\`;")"
fi

# ---------------------------------------------------------------- generadores de valor falso
# No se usan funciones almacenadas: crearlas exige log_bin_trust_function_creators o
# SUPER en servidores con binlog, y no vamos a tocar variables globales por esto. Las
# expresiones se arman aqui en bash y se repiten en el SQL.

NOMBRES="'MARIA','JOSE','CARMEN','LUIS','ROSA','JORGE','ANA','PEDRO','MARTHA','DIEGO',\
'SILVIA','ANGEL','GLORIA','FAUSTO','ELENA','MARCO','PATRICIA','HUGO','NELLY','IVAN'"
APELLIDOS="'PEREZ','GOMEZ','LOPEZ','TORRES','RAMIREZ','CASTRO','MORALES','VEGA','ROJAS','SALAZAR',\
'JARAMILLO','MONTERO','CEVALLOS','ANDRADE','BRAVO','ZAMBRANO','QUINTERO','PALACIOS','ARIAS','ORTEGA'"
VIAS="'CALLE','AVENIDA','BARRIO','SECTOR','VIA','CIUDADELA'"
LUGARES="'LOS SAUCES','SAN JOSE','LA PRADERA','EL BOSQUE','LAS PALMAS','SANTA ANA',\
'LOS ALAMOS','EL MIRADOR','LA FLORIDA','NUEVA UNION'"

# Numero estable derivado del valor original + la sal. Base de todo lo demas.
num_de() { printf "CAST(CONV(SUBSTRING(SHA2(CONCAT(@sal,COALESCE(%s,'')),256),1,12),16,10) AS UNSIGNED)" "$1"; }
# Cadena de N digitos sacada de ese numero (por la derecha, que es donde hay entropia).
dig_de() { printf "RIGHT(LPAD(%s,64,'4'),%s)" "$(num_de "$1")" "$2"; }

# Correo. Los errores no se eligen por ramas excluyentes sino que se COMPONEN: un
# correo real puede estar mal de varias maneras a la vez ("juan perez@gmailcom") y si
# el falso arreglase una de ellas el censo de casos sucios dejaria de cuadrar.
expr_correo() {
    local c="$1"
    cat <<SQL
CASE
  WHEN $c IS NULL THEN NULL
  WHEN TRIM($c) = '' THEN $c
  WHEN $c NOT LIKE '%@%' AND $c REGEXP '^[0-9]+\$' THEN $(dig_de "$c" "CHAR_LENGTH($c)")
  WHEN $c NOT LIKE '%@%' THEN CONCAT('cliente', $(dig_de "$c" 5), IF($c LIKE '% %', ' ', ''), 'ejemplo.test')
  ELSE CONCAT('cliente', $(dig_de "$c" 5),
              IF($c LIKE '% %', ' ', ''),
              IF($c LIKE '%@%@%', '@@', '@'),
              IF(SUBSTRING_INDEX($c,'@',-1) LIKE '%.%', 'ejemplo.test', 'ejemplotest'))
END
SQL
}

expr_telefono() {
    local c="$1"
    cat <<SQL
CASE
  WHEN $c IS NULL THEN NULL
  WHEN TRIM($c) = '' THEN $c
  WHEN $c REGEXP '^[0-9]{10}\$' THEN CONCAT('09', $(dig_de "$c" 8))
  WHEN $c REGEXP '^[0-9]+\$' THEN $(dig_de "$c" "CHAR_LENGTH($c)")
  ELSE REGEXP_REPLACE($c, '[0-9]', $(dig_de "$c" 1))
END
SQL
}

# Cedula / RUC: misma longitud y mismo formato aparente. Si venia sucio, sigue sucio.
expr_cedula() {
    local c="$1"
    cat <<SQL
CASE
  WHEN $c IS NULL THEN NULL
  WHEN TRIM($c) = '' THEN $c
  WHEN $c REGEXP '^[0-9]{13}\$' THEN CONCAT(LPAD(1 + ($(num_de "$c") % 24), 2, '0'), $(dig_de "$c" 8), '001')
  WHEN $c REGEXP '^[0-9]{10}\$' THEN CONCAT(LPAD(1 + ($(num_de "$c") % 24), 2, '0'), $(dig_de "$c" 8))
  WHEN $c REGEXP '^[0-9]+\$' THEN $(dig_de "$c" "CHAR_LENGTH($c)")
  ELSE REGEXP_REPLACE($c, '[0-9]', $(dig_de "$c" 1))
END
SQL
}

# Nombre completo. El sufijo numerico esta para que dos clientes distintos no colisionen
# en el mismo nombre falso: megahnet busca clientes por nombre.
expr_nombre() {
    local c="$1"
    cat <<SQL
CASE
  WHEN $c IS NULL THEN NULL
  WHEN TRIM($c) = '' THEN $c
  ELSE CONCAT(
    ELT(1 + ($(num_de "$c") % 20), $NOMBRES), ' ',
    ELT(1 + (($(num_de "$c") DIV 20) % 20), $APELLIDOS), ' ',
    ELT(1 + (($(num_de "$c") DIV 400) % 20), $APELLIDOS), ' ',
    $(dig_de "$c" 4))
END
SQL
}

expr_nombre_pila() {
    local c="$1"
    printf "CASE WHEN %s IS NULL THEN NULL WHEN TRIM(%s)='' THEN %s ELSE ELT(1 + (%s %% 20), %s) END" \
        "$c" "$c" "$c" "$(num_de "$c")" "$NOMBRES"
}

expr_apellido() {
    local c="$1"
    printf "CASE WHEN %s IS NULL THEN NULL WHEN TRIM(%s)='' THEN %s ELSE ELT(1 + (%s %% 20), %s) END" \
        "$c" "$c" "$c" "$(num_de "$c")" "$APELLIDOS"
}

expr_direccion() {
    local c="$1"
    cat <<SQL
CASE
  WHEN $c IS NULL THEN NULL
  WHEN TRIM($c) = '' THEN $c
  ELSE CONCAT(
    ELT(1 + ($(num_de "$c") % 6), $VIAS), ' ',
    ELT(1 + (($(num_de "$c") DIV 6) % 10), $LUGARES), ' ',
    1 + ($(num_de "$c") % 300))
END
SQL
}

# Coordenada: si era un par valido sale otro par valido (misma provincia aproximada);
# si era basura sigue siendo basura, porque hay pantallas que se rompen con eso.
expr_coordenada() {
    local c="$1"
    cat <<SQL
CASE
  WHEN $c IS NULL THEN NULL
  WHEN TRIM($c) = '' THEN $c
  WHEN $c REGEXP '^ *-?[0-9]+[.][0-9]+ *, *-?[0-9]+[.][0-9]+ *\$'
    THEN CONCAT('-3.', LPAD($(num_de "$c") % 10000, 4, '0'), ',-79.', LPAD(($(num_de "$c") DIV 10000) % 10000, 4, '0'))
  ELSE 'COORDENADA NO VALIDA'
END
SQL
}

# Texto libre: se conserva la LONGITUD (hay vistas que desbordan con comentarios largos)
# pero no el contenido, que suele traer nombres y telefonos sueltos.
expr_texto() {
    local c="$1"
    printf "CASE WHEN %s IS NULL THEN NULL WHEN TRIM(%s)='' THEN %s ELSE RPAD('TEXTO ANONIMIZADO', CHAR_LENGTH(%s), '.') END" \
        "$c" "$c" "$c" "$c"
}

# IP: se cambian los dos primeros octetos y se conservan los dos ultimos. Al aplicarse
# igual a contratos, pools y equipos, las relaciones por texto siguen cuadrando.
expr_ip() {
    local c="$1"
    cat <<SQL
CASE
  WHEN $c IS NULL THEN NULL
  WHEN TRIM($c) = '' THEN $c
  WHEN $c REGEXP '^[0-9]{1,3}[.][0-9]{1,3}[.]'
    THEN CONCAT('10.77.', SUBSTRING($c, CHAR_LENGTH(SUBSTRING_INDEX($c, '.', 2)) + 2))
  ELSE $c
END
SQL
}

# ---------------------------------------------------------------- plan de anonimizado
# tabla:columna:tipo — el tipo decide la expresion. Lo que no exista en el esquema del
# servidor se salta y se lista al final.
PLAN=(
    # el cliente
    "clientes:nombre:nombre"
    "clientes:num_identidad:cedula"
    "clientes:correo:correo"
    "clientes:telefono:telefono"
    "clientes:direccion:direccion"
    "clientes:coordenada:coordenada"
    "clientes:observacion:texto"

    # foto del cliente al emitir la factura electronica (el nombre va aparte, por id)
    "datos_cabecera_electronica:ruc:cedula"
    "datos_cabecera_electronica:correo:correo"
    "datos_cabecera_electronica:telefono:telefono"
    "datos_cabecera_electronica:direccion:direccion"

    # foto del cliente en nota de credito y retencion (mismo problema, misma receta)
    "nota_credito_cabecera:ruc_cliente:cedula"
    "retencion:ruc:cedula"
    "retencion:correo:correo"
    "retencion:telefono:telefono"
    "retencion:direccion:direccion"

    # orden de venta: en el esquema actual no lleva datos personales (van por
    # id_cliente). Se declaran igual: si manana aparecen, se anonimizan solas.
    "orden_venta:cliente:nombre"
    "orden_venta:nombre:nombre"
    "orden_venta:correo:correo"
    "orden_venta:telefono:telefono"
    "orden_venta:direccion:direccion"
    "orden_venta:ruc:cedula"

    # contratos
    "contratos:direccion:direccion"
    "contratos:comentario:texto"
    "contratos:coordenada:coordenada"
    "contratos:ip_usuario:ip"

    # proveedores: tambien son personas y empresas reales
    "proveedor:nombre:nombre"
    "proveedor:ruc:cedula"
    "proveedor:correo:correo"
    "proveedor:telefono:telefono"
    "proveedor:direccion:direccion"

    # usuarios del sistema (la clave se trata aparte)
    "usuarios:nombre:nombre_pila"
    "usuarios:apellido:apellido"
    "usuarios:correo:correo"
    "usuarios:telefono:telefono"
    "usuarios:direccion:direccion"

    # direccionamiento: mismo cambio que en contratos, para no romper la coherencia
    "ip:red:ip"
    "ip:gateway:ip"
    "ip:final:ip"
    "ip:ultima:ip"
    "ip_anuladas:ip:ip"
    "mikrotik:ip:ip"
    "repetidoras:ip:ip"
)

TOCADAS=()      # tabla.columna anonimizadas
OMITIDAS=()     # tabla.columna del plan que no existen en este esquema

: > "$SQL"
{
    printf -- "-- Generado por scripts/anonimizar.sh. Se ejecuta sobre la base temporal.\n"
    # NO_AUTO_VALUE_ON_ZERO y sin modo estricto: un volcado de produccion trae fechas
    # cero y textos al limite; no queremos que un UPDATE aborte por eso.
    printf "SET SESSION sql_mode = 'NO_AUTO_VALUE_ON_ZERO';\n"
    printf "SET @sal = '%s';\n" "$SAL"
} >> "$SQL"

# Copia de `clientes` ANTES de tocar nada: es la unica forma de dar a cada foto
# historica el mismo nombre falso que a su cliente, incluso cuando la foto guarda el
# nombre recortado a 75 o 100 caracteres.
HAY_MAPA=0
if hay "clientes.id" && hay "clientes.nombre"; then
    {
        printf "DROP TABLE IF EXISTS \`_mapa_clientes\`;\n"
        printf "CREATE TABLE \`_mapa_clientes\` AS SELECT \`id\`, \`nombre\` FROM \`clientes\`;\n"
        printf "ALTER TABLE \`_mapa_clientes\` ADD PRIMARY KEY (\`id\`);\n"
    } >> "$SQL"
    HAY_MAPA=1
fi

for foto in "datos_cabecera_electronica:cliente" "nota_credito_cabecera:cliente"; do
    tabla="${foto%%:*}"; columna="${foto#*:}"
    hay "$tabla.$columna" || { OMITIDAS+=("$tabla.$columna"); continue; }
    if [[ "$HAY_MAPA" -eq 1 ]] && hay "$tabla.id_cliente"; then
        {
            printf "UPDATE \`%s\` d JOIN \`_mapa_clientes\` m ON m.\`id\` = d.\`id_cliente\`\n" "$tabla"
            printf "   SET d.\`%s\` = %s;\n" "$columna" "$(expr_nombre "m.\`nombre\`")"
            # Filas sin cliente vinculado: no hay a quien parecerse, se deriva del texto.
            printf "UPDATE \`%s\` d SET d.\`%s\` = %s\n" "$tabla" "$columna" "$(expr_nombre "d.\`$columna\`")"
            printf " WHERE NOT EXISTS (SELECT 1 FROM \`_mapa_clientes\` m WHERE m.\`id\` = d.\`id_cliente\`);\n"
        } >> "$SQL"
    else
        # Sin tabla `clientes` en el volcado (o sin id_cliente) solo queda el texto.
        printf "UPDATE \`%s\` SET \`%s\` = %s;\n" \
            "$tabla" "$columna" "$(expr_nombre "\`$columna\`")" >> "$SQL"
    fi
    TOCADAS+=("$tabla.$columna")
done

# Resto del plan.
for entrada in "${PLAN[@]}"; do
    IFS=':' read -r tabla columna tipo <<< "$entrada"
    if ! hay "$tabla.$columna"; then
        OMITIDAS+=("$tabla.$columna")
        continue
    fi
    col="\`$columna\`"
    case "$tipo" in
        nombre)      valor="$(expr_nombre "$col")" ;;
        nombre_pila) valor="$(expr_nombre_pila "$col")" ;;
        apellido)    valor="$(expr_apellido "$col")" ;;
        cedula)      valor="$(expr_cedula "$col")" ;;
        correo)      valor="$(expr_correo "$col")" ;;
        telefono)    valor="$(expr_telefono "$col")" ;;
        direccion)   valor="$(expr_direccion "$col")" ;;
        coordenada)  valor="$(expr_coordenada "$col")" ;;
        texto)       valor="$(expr_texto "$col")" ;;
        ip)          valor="$(expr_ip "$col")" ;;
        *)           morir "tipo de anonimizado desconocido en el plan: $tipo" ;;
    esac
    printf "UPDATE \`%s\` SET %s = %s;\n" "$tabla" "$col" "$valor" >> "$SQL"
    TOCADAS+=("$tabla.$columna")
done

# ---------------------------------------------------------------- credenciales
# Todas las claves de usuario pasan al mismo hash de laboratorio (documentado arriba).
if hay "usuarios.clave"; then
    printf "UPDATE \`usuarios\` SET \`clave\` = '%s';\n" \
        '$2y$10$hGq8qxyd6AbBYYody0CInOF7SQ81e47/9X2JzT0ojnrvfIXFKGIW6' >> "$SQL"
    TOCADAS+=("usuarios.clave")
fi
# Los tokens de sesion valen para suplantar a alguien: fuera.
if hay "usuarios.token"; then
    printf "UPDATE \`usuarios\` SET \`token\` = NULL;\n" >> "$SQL"
    TOCADAS+=("usuarios.token")
fi

# Equipos MikroTik: credenciales reales de produccion dentro del volcado. Se invalidan.
if hay "mikrotik.clave"; then
    printf "UPDATE \`mikrotik\` SET \`clave\` = 'ANONIMIZADO-NO-VALIDO';\n" >> "$SQL"
    TOCADAS+=("mikrotik.clave")
fi
if hay "mikrotik.usuario"; then
    printf "UPDATE \`mikrotik\` SET \`usuario\` = 'laboratorio';\n" >> "$SQL"
    TOCADAS+=("mikrotik.usuario")
fi
# El ultimo error de conexion suele traer IP y usuario del router en texto plano.
if hay "mikrotik.ultimo_error"; then
    printf "UPDATE \`mikrotik\` SET \`ultimo_error\` = NULL;\n" >> "$SQL"
    TOCADAS+=("mikrotik.ultimo_error")
fi

# Identidad de la empresa y clave del certificado de firma. El .p12 no viaja en el
# volcado, pero la contrasena si: se deja en NULL para que el modulo de firma no
# arranque por accidente en el laboratorio.
if hay "configuracion.id"; then
    declare -A CONFIG_FIJA=(
        [ruc]="'9999999999001'"
        [nombre]="'EMPRESA LABORATORIO'"
        [razon_social]="'EMPRESA LABORATORIO S.A.'"
        [telefono]="'0990000000'"
        [correo]="'facturacion@ejemplo.test'"
        [direccion]="'DIRECCION DE LABORATORIO'"
        [firma_password]="NULL"
    )
    asignaciones=""
    for campo in ruc nombre razon_social telefono correo direccion firma_password; do
        if hay "configuracion.$campo"; then
            [[ -n "$asignaciones" ]] && asignaciones+=", "
            asignaciones+="\`$campo\` = ${CONFIG_FIJA[$campo]}"
            TOCADAS+=("configuracion.$campo")
        else
            OMITIDAS+=("configuracion.$campo")
        fi
    done
    [[ -n "$asignaciones" ]] && printf "UPDATE \`configuracion\` SET %s;\n" "$asignaciones" >> "$SQL"
fi

# ---------------------------------------------------------------- barrido generico
# Cualquier otra columna de texto que parezca correo o telefono en CUALQUIER tabla:
# se anonimiza con las mismas reglas (conservando NULL, vacios y errores) y se lista,
# porque no estaba en el plan y alguien deberia saberlo.
EXTRAS=()
sqlv "SELECT CONCAT(TABLE_NAME,'.',COLUMN_NAME)
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA='$BASE'
        AND DATA_TYPE IN ('char','varchar','tinytext','text','mediumtext','longtext')
        AND (COLUMN_NAME LIKE '%correo%' OR COLUMN_NAME LIKE '%mail%'
          OR COLUMN_NAME LIKE '%telefono%' OR COLUMN_NAME LIKE '%celular%'
          OR COLUMN_NAME LIKE '%whatsapp%' OR COLUMN_NAME LIKE '%phone%')
      ORDER BY TABLE_NAME, COLUMN_NAME;" > "$TRABAJO/extras.txt"

esta_tocada() {
    local ref="$1" x
    [[ "${#TOCADAS[@]}" -eq 0 ]] && return 1
    for x in "${TOCADAS[@]}"; do [[ "$x" == "$ref" ]] && return 0; done
    return 1
}

while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    esta_tocada "$ref" && continue
    tabla="${ref%%.*}"; columna="${ref#*.}"
    col="\`$columna\`"
    case "$columna" in
        *correo*|*mail*) valor="$(expr_correo "$col")" ;;
        *)               valor="$(expr_telefono "$col")" ;;
    esac
    printf "UPDATE \`%s\` SET %s = %s;\n" "$tabla" "$col" "$valor" >> "$SQL"
    TOCADAS+=("$ref")
    EXTRAS+=("$ref")
done < "$TRABAJO/extras.txt"

# La tabla puente sobra en la salida.
printf "DROP TABLE IF EXISTS \`_mapa_clientes\`;\n" >> "$SQL"

# ---------------------------------------------------------------- ejecucion
titulo "Anonimizando"
mysql --defaults-file="$CNF" "$BASE" < "$SQL"
msg "  ${#TOCADAS[@]} columnas anonimizadas"

# ---------------------------------------------------------------- comprobaciones
contar_filas "$TRABAJO/filas_despues.txt"
DIFERENCIAS="$(diff "$TRABAJO/filas_antes.txt" "$TRABAJO/filas_despues.txt" || true)"
if [[ -n "$DIFERENCIAS" ]]; then
    aviso "el numero de filas CAMBIO; esto no deberia pasar nunca:"
    printf '%s\n' "$DIFERENCIAS"
fi

declare -A CENSO_DESPUES=()
for ref in "${CORREOS_VIGILADOS[@]}"; do
    CENSO_DESPUES[$ref]="$(censo_correo "${ref%%.*}" "${ref#*.}")"
done
for ref in "${TELEFONOS_VIGILADOS[@]}"; do
    CENSO_DESPUES[$ref]="$(censo_telefono "${ref%%.*}" "${ref#*.}")"
done

# Si dos IP reales distintas acabasen en la misma IP falsa, el laboratorio tendria dos
# contratos compartiendo IP y eso si cambia el comportamiento. Se compara el recuento.
if [[ -n "${IP_DISTINTAS_ANTES:-}" ]]; then
    IP_DISTINTAS="$(sqlv "SELECT COUNT(DISTINCT \`ip_usuario\`) FROM \`contratos\`;")"
    if [[ "$IP_DISTINTAS" == "$IP_DISTINTAS_ANTES" ]]; then
        msg "  IP de contratos: $IP_DISTINTAS distintas, las mismas que antes"
    else
        aviso "las IP de contratos pasaron de $IP_DISTINTAS_ANTES distintas a $IP_DISTINTAS: hay colisiones"
    fi
fi

# ---------------------------------------------------------------- volcado de salida
titulo "Generando el volcado anonimizado"
PARCIAL="$TRABAJO/salida.sql"
mysqldump --defaults-file="$CNF" \
    --single-transaction --quick --no-tablespaces --skip-dump-date \
    --routines --events --triggers \
    "$BASE" > "$PARCIAL"

if [[ "$SALIDA_GZ" -eq 1 ]]; then
    gzip -c -- "$PARCIAL" > "$PARCIAL.gz"
    PARCIAL="$PARCIAL.gz"
fi
# Se mueve al final, de una pieza: si el script muere antes, no queda media salida.
mv -f -- "$PARCIAL" "$SALIDA"

# ---------------------------------------------------------------- resumen
titulo "RESUMEN"

msg "Columnas anonimizadas (${#TOCADAS[@]}):"
printf '%s\n' "${TOCADAS[@]}" | sort | awk -F. '
    { col[$1] = col[$1] " " $2; n[$1]++ }
    END { for (t in col) printf("  %-32s %s\n", t, col[t]) }' | sort

msg ""
msg "Filas por tabla tocada (ninguna se borro ni se creo):"
while IFS= read -r ref; do
    tabla="${ref%%.*}"
    printf '%s\n' "$tabla"
done < <(printf '%s\n' "${TOCADAS[@]}") | sort -u | while IFS= read -r tabla; do
    filas="$(awk -F'\t' -v t="$tabla" '$1 == t { print $2 }' "$TRABAJO/filas_despues.txt")"
    printf '  %-32s %s filas\n' "$tabla" "${filas:-?}"
done

msg ""
msg "Casos sucios conservados (antes -> despues; tienen que coincidir):"
msg "  correos:  total | nulos | vacios | sin arroba | con espacios | dominio sin punto | solo digitos"
for ref in "${CORREOS_VIGILADOS[@]}"; do
    [[ -n "${CENSO_ANTES[$ref]:-}" ]] || continue
    if [[ "${CENSO_ANTES[$ref]}" == "${CENSO_DESPUES[$ref]:-}" ]]; then
        printf '  %-36s %s   OK\n' "$ref" "${CENSO_ANTES[$ref]}"
    else
        aviso "$ref cambio de perfil: ${CENSO_ANTES[$ref]} -> ${CENSO_DESPUES[$ref]:-(sin dato)}"
    fi
done
msg "  telefonos: total | nulos | vacios | no numericos | longitud distinta de 10"
for ref in "${TELEFONOS_VIGILADOS[@]}"; do
    [[ -n "${CENSO_ANTES[$ref]:-}" ]] || continue
    if [[ "${CENSO_ANTES[$ref]}" == "${CENSO_DESPUES[$ref]:-}" ]]; then
        printf '  %-36s %s   OK\n' "$ref" "${CENSO_ANTES[$ref]}"
    else
        aviso "$ref cambio de perfil: ${CENSO_ANTES[$ref]} -> ${CENSO_DESPUES[$ref]:-(sin dato)}"
    fi
done

if [[ "${#EXTRAS[@]}" -gt 0 ]]; then
    msg ""
    msg "Columnas de correo/telefono fuera del plan, anonimizadas igual (revisar que toque):"
    printf '  %s\n' "${EXTRAS[@]}"
fi

if [[ "${#OMITIDAS[@]}" -gt 0 ]]; then
    msg ""
    msg "Del plan, no existen en este esquema (se saltaron, sin romper nada):"
    printf '  %s\n' "${OMITIDAS[@]}" | sort -u
fi

# Lo que huele a dato personal o a credencial y NO se anonimizo: decide una persona.
msg ""
msg "SIN ANONIMIZAR — columnas sospechosas que deberia mirar una persona:"
PENDIENTES=0
while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    esta_tocada "$ref" && continue
    tabla="${ref%%.*}"; columna="${ref#*.}"
    con_datos="$(sqlv "SELECT COUNT(*) FROM \`$tabla\` WHERE TRIM(COALESCE(\`$columna\`,'')) <> '';")"
    [[ "${con_datos:-0}" -gt 0 ]] || continue
    printf '  %-48s %s filas con contenido\n' "$ref" "$con_datos"
    PENDIENTES=$((PENDIENTES + 1))
done < <(sqlv "SELECT CONCAT(TABLE_NAME,'.',COLUMN_NAME)
               FROM information_schema.COLUMNS
               WHERE TABLE_SCHEMA='$BASE'
                 AND DATA_TYPE IN ('char','varchar','tinytext','text','mediumtext','longtext')
                 AND (COLUMN_NAME LIKE '%nombre%'    OR COLUMN_NAME LIKE '%apellido%'
                   OR COLUMN_NAME LIKE '%direccion%' OR COLUMN_NAME LIKE '%cedula%'
                   OR COLUMN_NAME LIKE '%identidad%' OR COLUMN_NAME LIKE '%ruc%'
                   OR COLUMN_NAME LIKE '%coordenada%' OR COLUMN_NAME LIKE '%observacion%'
                   OR COLUMN_NAME LIKE '%comentario%' OR COLUMN_NAME LIKE '%clave%'
                   OR COLUMN_NAME LIKE '%password%'  OR COLUMN_NAME LIKE '%contrasena%'
                   OR COLUMN_NAME LIKE '%token%'     OR COLUMN_NAME LIKE '%secret%'
                   OR COLUMN_NAME LIKE '%api%'       OR COLUMN_NAME LIKE '%usuario%')
               ORDER BY TABLE_NAME, COLUMN_NAME;")
[[ "$PENDIENTES" -eq 0 ]] && msg "  (ninguna con contenido)"

msg ""
msg "Volcado anonimizado: $SALIDA ($(du -h -- "$SALIDA" | cut -f1))"
msg "Todos los usuarios quedan con la clave de laboratorio documentada en la cabecera de este script."
msg "La entrada no se modifico: $ENTRADA"
if [[ "$AVISOS" -gt 0 ]]; then
    msg "Terminado con $AVISOS aviso(s): leelos antes de cargar esto en la maquina de pruebas."
else
    msg "Terminado sin avisos."
fi
