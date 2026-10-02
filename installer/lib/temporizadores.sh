#!/usr/bin/env bash
# temporizadores.sh — define, instala y verifica las tareas programadas de megahnet.
#
# POR QUE EXISTE ESTE ARCHIVO
# ---------------------------
# Hoy el instalador de megahnet no crea NINGUNA unidad de systemd. Los
# temporizadores de produccion se pusieron a mano, maquina por maquina, y nadie
# tiene la lista. El 2026-10-01 eso costo dinero: a una de las siete maquinas le
# faltaba el temporizador de ordenes de venta, no se facturo ese mes, y no salto
# ningun aviso — un fallo total y un mes tranquilo se ven igual desde el panel.
#
# Aqui la programacion deja de ser folclore: esta escrita, es la misma en las
# siete maquinas, y se puede comprobar.
#
# Se puede cargar desde un instalador:   source installer/lib/temporizadores.sh
# o ejecutar suelta para ver que haria:  bash installer/lib/temporizadores.sh estado
#
# ATENCION: los horarios de abajo son los VALORES POR DEFECTO de este laboratorio.
# Antes de llevarlos a produccion hay que comparar con las unidades que ya
# funcionan en las maquinas actuales y quedarse con lo que la operacion espera.
# Este archivo no decide a que hora cobra una empresa; solo deja de perderlo.

# ---------------------------------------------------------------------------
# Catalogo de tareas.
# Formato:  nombre | script | OnCalendar | segundos de plazo | usuario | descripcion
#
# Notas de las decisiones:
# - Persistent=true en las mensuales: si la maquina estaba apagada a la hora, la
#   tarea se ejecuta al volver. Sin esto, un reinicio a destiempo se come el mes.
# - La facturacion mensual lleva un plazo largo (2 h): cada factura habla con el
#   SRI y son cientos de contratos. El plazo corto es justo lo que sospechamos
#   que corta la facturacion a la mitad en produccion.
# - Las ordenes de venta arrancan 30 min despues de las facturas para no pelearse
#   por la base ni por el SRI.
# - El respaldo corre como root porque escribe en /root/backups; el resto corre
#   como el usuario del servidor web, que es el dueno de storage/ y de los PDF.
# ---------------------------------------------------------------------------
MEGAHNET_TAREAS=(
  "facturacion-mensual|cron/cron_facturacion_automaticas.php|*-*-01 02:00:00|7200|__WEBUSER__|Facturacion mensual de contratos con factura electronica"
  "facturacion-ordenventa|cron/cron_facturacion_ordenventa.php|*-*-01 02:30:00|7200|__WEBUSER__|Facturacion mensual de contratos con orden de venta"
  "sri-facturas|cron/cron_sri_facturas.php|*:0/10|1200|__WEBUSER__|Envio y autorizacion de comprobantes en el SRI"
  "sri-reintentos|cron/cron_sri_reintentos.php|*:5/10|1200|__WEBUSER__|Reintento de comprobantes que el SRI no autorizo"
  "envio-correo|cron/cron_envio_correo.php|*:0/10|1800|__WEBUSER__|Envio por correo de las facturas autorizadas"
  "verificar-mikrotiks|cron/cron_verificar_mikrotiks.php|*:0/30|600|__WEBUSER__|Comprobacion de conexion con los MikroTik"
  "respaldo-email|cron/cron_respaldo_email.php|*-*-* 03:30:00|3600|root|Respaldo diario de la base de datos"
)

# Valores por defecto; un instalador puede exportarlos antes de cargar este archivo.
: "${MEGAHNET_DIR:=/var/www/megahnet}"
: "${MEGAHNET_WEBUSER:=www-data}"
: "${MEGAHNET_SYSTEMD_DIR:=/etc/systemd/system}"
: "${MEGAHNET_PHP:=/usr/bin/php}"

temporizadores_log()  { printf '  %s\n' "$*"; }
temporizadores_warn() { printf '  AVISO: %s\n' "$*" >&2; }

# Genera el contenido de una unidad .service.
# El endurecimiento es deliberadamente moderado: NoNewPrivileges y PrivateTmp no
# rompen nada, mientras que aislar el sistema de ficheros si lo haria (estos
# procesos escriben PDF, XML y registros dentro del propio proyecto).
_temporizador_service() {
    local nombre="$1" script="$2" plazo="$3" usuario="$4" descripcion="$5"
    cat <<FIN
[Unit]
Description=megahnet: $descripcion
Documentation=https://github.com/mtandazo35/megahnet
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=oneshot
User=$usuario
WorkingDirectory=$MEGAHNET_DIR
ExecStart=$MEGAHNET_PHP $MEGAHNET_DIR/$script
TimeoutSec=$plazo
NoNewPrivileges=true
PrivateTmp=true
StandardOutput=append:$MEGAHNET_DIR/storage/cron_${nombre}.log
StandardError=append:$MEGAHNET_DIR/storage/cron_${nombre}.log
FIN
}

# Genera el contenido de una unidad .timer.
_temporizador_timer() {
    local nombre="$1" calendario="$2" descripcion="$3"
    cat <<FIN
[Unit]
Description=megahnet (temporizador): $descripcion

[Timer]
OnCalendar=$calendario
# Si la maquina estaba apagada a la hora prevista, se ejecuta al volver.
# Sin esto, un reinicio a destiempo se come la facturacion del mes.
Persistent=true
# Un poco de desfase para que las siete maquinas no golpeen el SRI a la vez.
RandomizedDelaySec=120
Unit=megahnet-${nombre}.service

[Install]
WantedBy=timers.target
FIN
}

# Instala (o actualiza) todas las unidades. Idempotente: si el contenido ya es
# el mismo, no reescribe ni reinicia nada.
# Una unidad que existe y DIFIERE no se pisa en silencio: se avisa y se respeta,
# salvo que se pida explicitamente con MEGAHNET_TIMERS_FORZAR=1. Esto importa
# porque las maquinas en marcha ya tienen horarios que la operacion espera.
temporizadores_instalar() {
    local forzar="${MEGAHNET_TIMERS_FORZAR:-0}"
    local cambios=0 respetadas=0

    command -v systemctl >/dev/null 2>&1 || { temporizadores_warn "systemd no disponible"; return 1; }

    local tarea nombre script calendario plazo usuario descripcion
    for tarea in "${MEGAHNET_TAREAS[@]}"; do
        IFS='|' read -r nombre script calendario plazo usuario descripcion <<< "$tarea"
        usuario="${usuario/__WEBUSER__/$MEGAHNET_WEBUSER}"

        if [[ ! -f "$MEGAHNET_DIR/$script" ]]; then
            temporizadores_warn "no existe $script; se omite $nombre"
            continue
        fi

        local destino_s="$MEGAHNET_SYSTEMD_DIR/megahnet-${nombre}.service"
        local destino_t="$MEGAHNET_SYSTEMD_DIR/megahnet-${nombre}.timer"
        local nuevo_s nuevo_t
        nuevo_s="$(_temporizador_service "$nombre" "$script" "$plazo" "$usuario" "$descripcion")"
        nuevo_t="$(_temporizador_timer "$nombre" "$calendario" "$descripcion")"

        local escribir=1
        if [[ -f "$destino_s" && -f "$destino_t" ]]; then
            if [[ "$(cat "$destino_s")" == "$nuevo_s" && "$(cat "$destino_t")" == "$nuevo_t" ]]; then
                escribir=0
            elif [[ "$forzar" != "1" ]]; then
                temporizadores_warn "megahnet-$nombre ya existe y es DISTINTA; se respeta (MEGAHNET_TIMERS_FORZAR=1 para reemplazar)"
                respetadas=$((respetadas+1))
                escribir=0
            fi
        fi

        if [[ "$escribir" == "1" ]]; then
            printf '%s\n' "$nuevo_s" > "$destino_s"
            printf '%s\n' "$nuevo_t" > "$destino_t"
            chmod 0644 "$destino_s" "$destino_t"
            cambios=$((cambios+1))
            temporizadores_log "escrita  megahnet-$nombre ($calendario)"
        fi
    done

    if (( cambios > 0 )); then
        systemctl daemon-reload
    fi

    for tarea in "${MEGAHNET_TAREAS[@]}"; do
        IFS='|' read -r nombre _ _ _ _ _ <<< "$tarea"
        [[ -f "$MEGAHNET_SYSTEMD_DIR/megahnet-${nombre}.timer" ]] || continue
        systemctl enable --now "megahnet-${nombre}.timer" >/dev/null 2>&1 \
            || temporizadores_warn "no se pudo activar megahnet-${nombre}.timer"
    done

    temporizadores_log "unidades escritas: $cambios, respetadas por ser distintas: $respetadas"
    return 0
}

# Comprueba que TODO lo del catalogo existe y esta activo. Devuelve error si falta
# alguno: esta es la comprobacion que habria delatado el mes sin facturar.
temporizadores_verificar() {
    local faltan=0 tarea nombre
    printf '  %-26s %-10s %s\n' "TAREA" "ESTADO" "PROXIMA EJECUCION"
    for tarea in "${MEGAHNET_TAREAS[@]}"; do
        IFS='|' read -r nombre _ _ _ _ _ <<< "$tarea"
        local unidad="megahnet-${nombre}.timer"
        if ! systemctl list-unit-files "$unidad" >/dev/null 2>&1 || \
           [[ ! -f "$MEGAHNET_SYSTEMD_DIR/$unidad" ]]; then
            printf '  %-26s %-10s %s\n' "$nombre" "NO EXISTE" "-"
            faltan=$((faltan+1)); continue
        fi
        local activo proxima
        activo=$(systemctl is-active "$unidad" 2>/dev/null || true)
        proxima=$(systemctl list-timers --all --no-pager "$unidad" 2>/dev/null | awk 'NR==2{print $1" "$2" "$3}')
        printf '  %-26s %-10s %s\n' "$nombre" "$activo" "${proxima:-desconocida}"
        [[ "$activo" == "active" ]] || faltan=$((faltan+1))
    done
    if (( faltan > 0 )); then
        temporizadores_warn "faltan o estan inactivos $faltan temporizador(es)"
        return 1
    fi
    return 0
}

# Muestra lo que se instalaria, sin tocar nada. Util para revisar antes de aplicar.
temporizadores_mostrar() {
    local tarea nombre script calendario plazo usuario descripcion
    for tarea in "${MEGAHNET_TAREAS[@]}"; do
        IFS='|' read -r nombre script calendario plazo usuario descripcion <<< "$tarea"
        usuario="${usuario/__WEBUSER__/$MEGAHNET_WEBUSER}"
        printf '  %-26s %-22s plazo %5ss  como %-9s %s\n' \
               "megahnet-$nombre" "$calendario" "$plazo" "$usuario" "$script"
    done
}

# Ejecucion suelta: solo para mirar. Instalar requiere llamarlo desde el instalador.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -Eeuo pipefail
    case "${1:-mostrar}" in
        mostrar)   echo "Tareas definidas (nada se instala):"; temporizadores_mostrar ;;
        estado)    temporizadores_verificar ;;
        instalar)  [[ "$(id -u)" -eq 0 ]] || { echo "Instalar requiere root" >&2; exit 1; }
                   temporizadores_instalar && temporizadores_verificar ;;
        *)         echo "Uso: $0 [mostrar|estado|instalar]" >&2; exit 2 ;;
    esac
fi
