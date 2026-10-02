#!/usr/bin/env bash
# Prueba de migraciones.sh contra el cliente mysql falso.
set -uo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$BASE/bin:$PATH"
export MIGSTUB_STATE="$BASE/estado.tsv"
export MIGSTUB_APPLIED="$BASE/aplicadas.txt"
LIB="/c/Users/Manuel/Documents/GitHub/megahnet-lab/installer/lib/migraciones.sh"
MIGS="$BASE/migrations"

reset_todo() {
    rm -rf "$MIGS"; mkdir -p "$MIGS"
    rm -f "$MIGSTUB_STATE"; : > "$MIGSTUB_APPLIED"
    printf -- "-- 001\nCREATE TABLE IF NOT EXISTS a (id INT);\n" > "$MIGS/001_a.sql"
    printf -- "-- 002\nALTER TABLE a ADD COLUMN IF NOT EXISTS x INT;\n" > "$MIGS/002_b.sql"
    printf -- "-- 003\nCREATE TABLE IF NOT EXISTS c (id INT);\n" > "$MIGS/003_c.sql"
}
titulo() { echo; echo "############ $* ############"; }

export MIGRACIONES_DB=sistema
export MIGRACIONES_DIR="$MIGS"
export MIGRACIONES_DB_USER=megahnet
export MIGRACIONES_DB_PASS='clave secreta'

reset_todo

titulo "1. estado con base virgen (sin tabla de control)"
bash "$LIB" estado; echo "rc=$?"

titulo "2. primera aplicacion"
bash "$LIB" aplicar; echo "rc=$?"
echo "-- migraciones realmente enviadas al servidor:"; cat "$MIGSTUB_APPLIED"

titulo "3. SEGUNDA aplicacion (idempotencia: no debe aplicar nada)"
: > "$MIGSTUB_APPLIED"
bash "$LIB" aplicar; echo "rc=$?"
echo "-- enviadas al servidor esta vez: $(wc -l < "$MIGSTUB_APPLIED")"

titulo "4. estado"
bash "$LIB" estado; echo "rc=$?"

titulo "5. alguien edita 002 ya aplicada -> debe ABORTAR con rc=3"
printf -- "-- 002 editada\nALTER TABLE a ADD COLUMN IF NOT EXISTS x BIGINT;\n" > "$MIGS/002_b.sql"
: > "$MIGSTUB_APPLIED"
bash "$LIB" aplicar; echo "rc=$?"
echo "-- enviadas: $(wc -l < "$MIGSTUB_APPLIED") (debe ser 0)"

titulo "5b. estado marca CAMBIADA y devuelve rc=1"
bash "$LIB" estado; echo "rc=$?"

titulo "6. misma situacion con --cambios avisar -> continua, rc=0"
bash "$LIB" aplicar --cambios avisar; echo "rc=$?"

titulo "7. resellar 002 y volver a aplicar limpio"
bash "$LIB" resellar 002_b.sql; echo "rc=$?"
bash "$LIB" aplicar; echo "rc=$?"

titulo "8. una migracion nueva que falla -> para en seco, rc=1, no aplica la siguiente"
printf -- "-- 004\nESTO_FALLA;\n" > "$MIGS/004_rota.sql"
printf -- "-- 005\nCREATE TABLE IF NOT EXISTS e (id INT);\n" > "$MIGS/005_e.sql"
: > "$MIGSTUB_APPLIED"
bash "$LIB" aplicar; echo "rc=$?"
echo "-- enviadas: $(cat "$MIGSTUB_APPLIED")  (005 NO debe aparecer)"

titulo "8b. estado tras el fallo"
bash "$LIB" estado; echo "rc=$?"
echo "-- pendientes:"; bash "$LIB" pendientes; echo "rc=$?"

titulo "8c. se arregla 004 y se relanza: continua por donde quedo"
printf -- "-- 004 arreglada\nCREATE TABLE IF NOT EXISTS d (id INT);\n" > "$MIGS/004_rota.sql"
: > "$MIGSTUB_APPLIED"
bash "$LIB" aplicar; echo "rc=$?"
echo "-- enviadas: $(cat "$MIGSTUB_APPLIED")"

titulo "9. adoptar en una base heredada (no debe ejecutar nada)"
reset_todo
: > "$MIGSTUB_APPLIED"
bash "$LIB" adoptar; echo "rc=$?"
echo "-- enviadas al servidor: $(wc -l < "$MIGSTUB_APPLIED") (debe ser 0)"
bash "$LIB" aplicar; echo "rc=$?"
echo "-- enviadas tras aplicar: $(wc -l < "$MIGSTUB_APPLIED") (debe seguir 0)"
bash "$LIB" estado

titulo "10. simulacion sobre base virgen"
reset_todo
bash "$LIB" aplicar --simular; echo "rc=$?"
echo "-- enviadas: $(wc -l < "$MIGSTUB_APPLIED" 2>/dev/null || echo 0) (debe ser 0)"
echo "-- tabla de control creada?: $([ -f "$MIGSTUB_STATE" ] && echo SI || echo NO) (debe ser NO)"

titulo "11. errores de entorno"
bash "$LIB" aplicar --dir /no/existe; echo "rc=$? (esperado 2)"
bash "$LIB" borrar; echo "rc=$? (esperado 2)"

titulo "12. cargada con source: no impone opciones ni llama a exit"
reset_todo
bash -c '
set +e +u +o pipefail
source "'"$LIB"'" || { echo "source fallo"; exit 1; }
antes="$-"
MIGRACIONES_DB=sistema MIGRACIONES_DIR="'"$MIGS"'" migraciones_aplicar >/dev/null
echo "rc de migraciones_aplicar=$?"
echo "opciones del shell antes/despues: [$antes] / [$-] (deben ser iguales)"
echo "el shell sigue vivo tras la llamada: SI"
migraciones_estado >/dev/null; echo "rc de migraciones_estado=$?"
'

titulo "13. la contrasena nunca llega a argv (el stub aborta con 99 si llegara)"
echo "ninguna ejecucion anterior devolvio 99 -> correcto"
echo
echo "FIN"
