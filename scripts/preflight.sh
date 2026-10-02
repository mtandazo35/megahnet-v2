#!/usr/bin/env bash
# preflight.sh — comprueba si una maquina Debian sirve para montar el laboratorio.
#
# SOLO LECTURA: no instala, no escribe, no reinicia nada. Puede ejecutarse las veces
# que haga falta. Sirve para saber con que contamos ANTES de tocar la maquina.
#
# Uso:
#   bash scripts/preflight.sh 203.0.113.10          (por SSH, usuario root)
#   bash scripts/preflight.sh usuario@203.0.113.10
#   bash scripts/preflight.sh local                 (si ya estas dentro de la maquina)
set -uo pipefail

DESTINO="${1:-}"
if [[ -z "$DESTINO" ]]; then
    echo "Falta la maquina. Ejemplo: bash scripts/preflight.sh 203.0.113.10" >&2
    exit 2
fi

# --- requisitos del laboratorio (ajustables) -------------------------------
RAM_MINIMA_MB=3800        # 4 GB nominales
DISCO_MINIMO_GB=25
DEBIAN_SOPORTADO="12 13"

# El cuerpo se ejecuta igual en local que por SSH, para que lo que se comprueba
# sea exactamente lo mismo en los dos casos.
COMPROBACIONES=$(cat <<'FIN'
set -uo pipefail
ok=0; aviso=0; falla=0
linea() { printf '  %-28s %s\n' "$1" "$2"; }
si()    { linea "$1" "OK      $2"; ok=$((ok+1)); }
warn()  { linea "$1" "AVISO   $2"; aviso=$((aviso+1)); }
no()    { linea "$1" "FALLA   $2"; falla=$((falla+1)); }

echo "MAQUINA"
linea "hostname" "$(hostname)"
linea "fecha" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# --- sistema operativo ---
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    VER="${VERSION_ID:-?}"
    if [[ "$ID" == "debian" ]]; then
        if [[ " __DEBIAN__ " == *" $VER "* ]]; then si "sistema" "Debian $VER"
        else warn "sistema" "Debian $VER (probado en __DEBIAN__)"; fi
    else
        no "sistema" "$PRETTY_NAME (se espera Debian)"
    fi
else
    no "sistema" "no se pudo leer /etc/os-release"
fi
linea "arquitectura" "$(uname -m)"
linea "kernel" "$(uname -r)"

# --- recursos ---
RAM=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
[[ "$RAM" -ge __RAM__ ]] && si "memoria" "${RAM} MB" || no "memoria" "${RAM} MB (minimo __RAM__ MB)"
DISCO=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[[ "$DISCO" -ge __DISCO__ ]] && si "disco libre en /" "${DISCO} GB" || no "disco libre en /" "${DISCO} GB (minimo __DISCO__ GB)"
linea "procesadores" "$(nproc)"

# --- quien soy ---
[[ "$(id -u)" -eq 0 ]] && si "privilegios" "root" || warn "privilegios" "$(id -un), hara falta sudo"

# --- systemd: el laboratorio existe para probar esto ---
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    si "systemd" "activo ($(systemctl --version | head -1 | awk '{print $2}'))"
    TIMERS=$(systemctl list-timers --all --no-pager 2>/dev/null | grep -ci megahnet || true)
    linea "temporizadores megahnet" "$TIMERS encontrados"
else
    no "systemd" "no disponible (sin esto no se pueden probar los temporizadores)"
fi

# --- que hay ya instalado ---
echo
echo "PROGRAMAS"
for p in php mysql mariadb docker composer git curl tar gzip; do
    if command -v "$p" >/dev/null 2>&1; then
        linea "$p" "$("$p" --version 2>/dev/null | head -1 | cut -c1-48)"
    else
        linea "$p" "no instalado"
    fi
done

# --- ocupacion previa: que NO haya algo en marcha que vayamos a pisar ---
echo
echo "QUE HAY YA EN LA MAQUINA"
[[ -d /var/www/megahnet ]] && warn "/var/www/megahnet" "YA EXISTE, revisar antes de instalar" || si "/var/www/megahnet" "libre"
for puerto in 80 443 3306 3005 5432 6379; do
    if (command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$puerto ") ; then
        warn "puerto $puerto" "ocupado"
    else
        si "puerto $puerto" "libre"
    fi
done

# --- salida a internet (sin esto no hay apt ni composer ni GitHub) ---
echo
echo "RED"
if command -v getent >/dev/null 2>&1 && getent hosts deb.debian.org >/dev/null 2>&1; then
    si "resolucion DNS" "deb.debian.org responde"
else
    no "resolucion DNS" "no resuelve deb.debian.org"
fi
for destino in deb.debian.org github.com; do
    if curl -s -o /dev/null -m 8 "https://$destino"; then si "salida a $destino" ""; else no "salida a $destino" "sin respuesta"; fi
done
if [[ -r /etc/resolv.conf ]]; then
    MAL=$(grep -c '^nameserver[[:space:]].*[[:space:]].*[0-9]' /etc/resolv.conf 2>/dev/null || true)
    [[ "$MAL" -gt 0 ]] && warn "/etc/resolv.conf" "hay lineas con mas de un servidor (malformadas)"
fi

echo
echo "RESUMEN: $ok correctas, $aviso avisos, $falla fallas"
if [[ "$falla" -gt 0 ]]; then
    echo "LA MAQUINA NO SIRVE TAL CUAL: corrige las fallas antes de seguir."
    exit 1
fi
[[ "$aviso" -gt 0 ]] && echo "Sirve, pero hay avisos que conviene mirar."
echo "Preflight completado. No se modifico nada."
exit 0
FIN
)

COMPROBACIONES="${COMPROBACIONES//__RAM__/$RAM_MINIMA_MB}"
COMPROBACIONES="${COMPROBACIONES//__DISCO__/$DISCO_MINIMO_GB}"
COMPROBACIONES="${COMPROBACIONES//__DEBIAN__/$DEBIAN_SOPORTADO}"

echo "=============================================="
echo " MEGAHNET LAB — preflight (solo lectura)"
echo "=============================================="

if [[ "$DESTINO" == "local" ]]; then
    bash -c "$COMPROBACIONES"
else
    [[ "$DESTINO" == *"@"* ]] || DESTINO="root@$DESTINO"
    echo " Maquina: $DESTINO"
    echo
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$DESTINO" 'bash -s' <<< "$COMPROBACIONES"
fi
