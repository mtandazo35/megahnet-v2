#!/usr/bin/env bash
# Prueba de comportamiento de scripts/vps-sync.sh.
#
# Usa el script REAL contra un "VPS" simulado (una carpeta temporal: VPS_HOST=local)
# y un repositorio de juguete. No toca la red ni ningun servidor.
#
# Lo que mas importa: que si lo enviado viene roto, el VPS quede EXACTAMENTE como
# estaba, y que nunca viaje lo que no debe (.env, storage/, docker/).
#
# Uso:  bash scripts/tests/vps-sync.test.sh
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$AQUI/../vps-sync.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

ok=0; mal=0
comprobar() {  # comprobar "texto" 'condicion'
    if eval "$2"; then echo "  OK    $1"; ok=$((ok + 1))
    else               echo "  FALLA $1"; mal=$((mal + 1)); fi
}
hash_de() { sha256sum "$1" 2>/dev/null | cut -c1-64; }

# ---- repositorio de juguete y "VPS" -----------------------------------------
R="$T/repo"; V="$T/vps/app"; B="$T/vps/respaldos"
mkdir -p "$R/models" "$R/db/migrations" "$R/docker" "$R/docs" "$R/storage" "$R/scripts"
cd "$R"
git init -q && git config user.email t@example.org && git config user.name prueba
git config core.autocrlf false   # en Windows meteria \r y falsearia las comparaciones
printf '<?php echo 1;\n'      > index.php
printf '<?php class A {}\n'   > models/A.php
printf '#!/usr/bin/env bash\necho hola\n' > scripts/algo.sh   # con shebang, como uno real (Git Bash lo exige para ver el bit x)
printf 'CREATE TABLE x;\n'    > db/migrations/001.sql
printf 'servicios\n'          > docker/compose.yml
printf '# notas\n'            > docs/notas.md
printf 'SECRETO=1\n'          > .env
printf 'dato de cliente\n'    > storage/cliente.log
printf '.env\nstorage/\n'     > .gitignore
git add -A && git commit -qm base

printf '#!/usr/bin/env bash\n! grep -q SINTAXIS_ROTA "$1"\n' > "$T/lint.sh"
chmod +x "$T/lint.sh"
export VPS_HOST=local VPS_PATH="$V" VPS_BACKUP="$B" VPS_OWNER="" LINT_CMD="$T/lint.sh"
sync() { bash "$SYNC" "$@"; }

echo "base de pruebas: $T"
echo

# ---- 1. plan: informa y NO toca nada ----------------------------------------
echo "[plan]"
salida="$(sync plan 2>&1)"
comprobar "plan cuenta 4 archivos nuevos (index, modelo, .sh, migracion)"  'grep -q "nuevos=4" <<< "$salida"'
comprobar "plan no crea nada en el VPS"                                     '[ ! -e "$V/index.php" ]'
comprobar "plan avisa de la migracion"                                      'grep -qi "migraciones" <<< "$salida"'

# ---- 2. aplicar: llega lo correcto y solo eso -------------------------------
echo "[aplicar]"
sync aplicar > "$T/aplicar1.log" 2>&1
comprobar "llegan los 4 archivos"            '[ -f "$V/index.php" ] && [ -f "$V/models/A.php" ] && [ -f "$V/scripts/algo.sh" ] && [ -f "$V/db/migrations/001.sql" ]'
comprobar "el contenido es identico"         '[ "$(hash_de "$R/models/A.php")" = "$(hash_de "$V/models/A.php")" ]'
comprobar "NUNCA viaja .env"                 '[ ! -e "$V/.env" ]'
comprobar "NUNCA viaja storage/"             '[ ! -e "$V/storage" ]'
comprobar "NO viaja docker/ ni docs/"        '[ ! -e "$V/docker" ] && [ ! -e "$V/docs" ]'
comprobar "los .sh quedan ejecutables"       '[ -x "$V/scripts/algo.sh" ]'

# ---- 3. idempotencia y comparacion por contenido ----------------------------
echo "[idempotencia]"
salida="$(sync aplicar 2>&1)"
comprobar "volver a aplicar no envia nada"   'grep -q "Nada que enviar" <<< "$salida"'
touch "$R/models/A.php"                       # cambia la fecha, NO el contenido
salida="$(sync plan 2>&1)"
comprobar "cambiar solo la fecha no cuenta como cambio" 'grep -q "Nada que enviar" <<< "$salida"'

# ---- 4. un cambio real: modificado + nuevo, con respaldo --------------------
echo "[cambio real]"
antes_A="$(hash_de "$V/models/A.php")"
printf '<?php class A { function x() {} }\n' > "$R/models/A.php"
printf '<?php class B {}\n' > "$R/models/B.php"
salida="$(sync plan 2>&1)"
comprobar "plan: 1 nuevo y 1 modificado"     'grep -q "nuevos=1 modificados=1" <<< "$salida"'
sync aplicar > "$T/aplicar2.log" 2>&1
comprobar "llegan ambos"                     '[ "$(hash_de "$R/models/A.php")" = "$(hash_de "$V/models/A.php")" ] && [ -f "$V/models/B.php" ]'
comprobar "el respaldo guarda el A.php ORIGINAL" 'tar xzOf "$(ls -1 "$B"/*.tar.gz | tail -1)" models/A.php | grep -q "class A {}"'

# ---- 5. LO IMPORTANTE: si viene roto, todo vuelve atras ---------------------
echo "[rollback]"
antes_index="$(hash_de "$V/index.php")"
printf '<?php SINTAXIS_ROTA\n' > "$R/index.php"
printf '<?php class C {}\n'    > "$R/models/C.php"
sync aplicar > "$T/roto.log" 2>&1; codigo=$?
comprobar "el envio ROTO termina con error"                '[ "$codigo" -ne 0 ]'
comprobar "el archivo existente queda como estaba"         '[ "$(hash_de "$V/index.php")" = "$antes_index" ]'
comprobar "el archivo nuevo enviado junto se retira"       '[ ! -e "$V/models/C.php" ]'
comprobar "el error explica que fue la sintaxis"           'grep -qi "sintaxis" "$T/roto.log"'
git -C "$R" checkout -q index.php && rm -f "$R/models/C.php"

# ---- 6. deshacer ------------------------------------------------------------
echo "[deshacer]"
previo="$(hash_de "$V/models/A.php")"
printf '<?php class A { function y() {} }\n' > "$R/models/A.php"
sync aplicar > /dev/null 2>&1
comprobar "tras aplicar, el VPS tiene la version nueva"    '[ "$(hash_de "$V/models/A.php")" != "$previo" ]'
sync deshacer > /dev/null 2>&1
comprobar "deshacer devuelve la version anterior"          '[ "$(hash_de "$V/models/A.php")" = "$previo" ]'

# ---- 7. configuracion -------------------------------------------------------
echo "[configuracion]"
( unset VPS_HOST; bash "$SYNC" plan > "$T/sinhost.log" 2>&1 ); codigo=$?
comprobar "sin VPS_HOST se niega y explica"                '[ "$codigo" -ne 0 ] && grep -q "VPS_HOST" "$T/sinhost.log"'

echo
echo "$ok correctas, $mal fallidas"
exit $(( mal > 0 ))
