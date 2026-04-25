#!/usr/bin/env bash
# =============================================================================
# tello_monitor.sh — Monitor de estado del dron Tello (cada 5 segundos)
# Protocolo: Tello SDK 2.0
#   Comandos : UDP 192.168.10.1:8889  (PC → Tello)
#   Estado   : UDP 0.0.0.0:8890       (Tello → PC, ~10-20 Hz)
# =============================================================================

# ─── Configuración ────────────────────────────────────────────────────────────
TELLO_IP="192.168.10.1"
TELLO_CMD_PORT=8889
TELLO_STATE_PORT=8890
STATE_FILE="/tmp/tello_state_$$.txt"
INTERVAL=5

# ─── Colores ANSI ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Limpieza al salir (Ctrl+C / kill) ────────────────────────────────────────
cleanup() {
    tput cnorm 2>/dev/null                    # Restaurar cursor
    echo -e "\n${YELLOW}Cerrando monitor Tello...${NC}"
    jobs -p | xargs -r kill 2>/dev/null       # Matar todos los jobs background
    rm -f "$STATE_FILE"
    echo -e "${GREEN}Fin.${NC}"
    exit 0
}
trap cleanup INT TERM

# ─── Enviar comando UDP al Tello ──────────────────────────────────────────────
# Usa /dev/udp (built-in de bash), sin necesidad de herramientas externas.
send_command() {
    echo -n "$1" > /dev/udp/"$TELLO_IP"/"$TELLO_CMD_PORT" 2>/dev/null || true
}

# ─── Extraer campo del string de estado Tello ─────────────────────────────────
# Formato: pitch:v;roll:v;yaw:v;vgx:v;vgy:v;vgz:v;templ:v;temph:v;tof:v;h:v;bat:v;baro:v;time:v;...
# Divide por ";" y busca "^campo:" para evitar coincidencias parciales
# (p.ej. "h:" nunca coincide accidentalmente con "temph:").
get_field() {
    echo "$1" | tr ';' '\n' | awk -F':' -v f="$2" '$1==f{print $2; exit}'
}

# ─── Mostrar estado formateado ─────────────────────────────────────────────────
display_state() {
    local timestamp
    timestamp=$(date '+%H:%M:%S')

    if [[ ! -s "$STATE_FILE" ]]; then
        clear
        echo -e "\n  ${YELLOW}${BOLD}[ ${timestamp} ]${NC} Esperando datos del Tello..."
        echo -e "  ${DIM}¿Estás conectado a la red WiFi del Tello? (TELLO-XXXXXX)${NC}"
        return
    fi

    local state
    state=$(tail -1 "$STATE_FILE" 2>/dev/null | tr -d '\r\n')
    [[ -z "$state" ]] && return

    # ── Extraer campos esenciales ──────────────────────────────────────────────
    local bat h pitch roll yaw templ temph tof vgx vgy vgz baro tiempo
    bat=$(get_field   "$state" "bat")
    h=$(get_field     "$state" "h")
    pitch=$(get_field "$state" "pitch")
    roll=$(get_field  "$state" "roll")
    yaw=$(get_field   "$state" "yaw")
    templ=$(get_field "$state" "templ")
    temph=$(get_field "$state" "temph")
    tof=$(get_field   "$state" "tof")
    vgx=$(get_field   "$state" "vgx")
    vgy=$(get_field   "$state" "vgy")
    vgz=$(get_field   "$state" "vgz")
    baro=$(get_field  "$state" "baro")
    tiempo=$(get_field "$state" "time")

    # ── Color de batería según nivel ───────────────────────────────────────────
    local bat_color="$GREEN"
    local bat_num="${bat:-100}"
    if   [[ "$bat_num" =~ ^[0-9]+$ ]] && (( bat_num < 20 )); then
        bat_color="$RED"
    elif [[ "$bat_num" =~ ^[0-9]+$ ]] && (( bat_num < 50 )); then
        bat_color="$YELLOW"
    fi

    clear
    echo -e "${BOLD}${CYAN}  ╔═══════════════════════════════════════╗${NC}"
    printf  "${BOLD}${CYAN}  ║${NC}  TELLO MONITOR  —  ${BOLD}%s${NC}%20s${BOLD}${CYAN}║${NC}\n" \
            "$timestamp" " "
    echo -e "${BOLD}${CYAN}  ╚═══════════════════════════════════════╝${NC}"
    echo ""

    # Alimentación y altitud
    echo -e "  ${BOLD}Batería:${NC}          ${bat_color}${BOLD}${bat:-?}%${NC}"
    echo -e "  ${BOLD}Altura:${NC}           ${h:-?} cm"
    echo -e "  ${BOLD}Dist. ToF:${NC}        ${tof:-?} cm"
    echo -e "  ${BOLD}Barómetro:${NC}        ${baro:-?} cm"
    echo ""

    # Actitud (orientación)
    echo -e "  ${BOLD}${BLUE}Actitud${NC}"
    echo -e "    Pitch: ${pitch:-?}°    Roll: ${roll:-?}°    Yaw: ${yaw:-?}°"
    echo ""

    # Velocidades
    echo -e "  ${BOLD}${BLUE}Velocidad (cm/s)${NC}"
    echo -e "    Vx: ${vgx:-?}    Vy: ${vgy:-?}    Vz: ${vgz:-?}"
    echo ""

    # Temperatura y tiempo de motor
    echo -e "  ${BOLD}Temperatura:${NC}      ${templ:-?}°C – ${temph:-?}°C"
    echo -e "  ${BOLD}Tiempo motor:${NC}     ${tiempo:-?} s"
    echo ""
    echo -e "  ${DIM}Actualización: cada ${INTERVAL}s  |  Ctrl+C para salir${NC}"
}

# ─── Listener UDP de estado (puerto 8890) ─────────────────────────────────────
# El Tello envía el estado de forma continua; guardamos siempre la línea más reciente.
# Orden de preferencia: socat > python3 > nc
start_state_listener() {
    if command -v socat &>/dev/null; then
        # "fork" mantiene el socket abierto entre paquetes UDP
        (socat -u UDP-RECVFROM:"$TELLO_STATE_PORT",reuseaddr,fork STDOUT 2>/dev/null \
            | while IFS= read -r line; do
                [[ -n "$line" ]] && printf '%s\n' "$line" > "$STATE_FILE"
              done) &

    elif command -v python3 &>/dev/null; then
        # Python: disponible en este proyecto y fiable en cualquier plataforma
        python3 - "$STATE_FILE" "$TELLO_STATE_PORT" <<'PYEOF' &
import socket, sys, time
sf   = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(('', port))
while True:
    try:
        data, _ = sock.recvfrom(1024)
        line = data.decode('utf-8', errors='ignore').strip()
        if line:
            with open(sf, 'w') as f:
                f.write(line + '\n')
    except Exception:
        time.sleep(0.1)
PYEOF

    elif command -v nc &>/dev/null; then
        # nc como último recurso; bucle para reiniciar si nc sale tras un paquete
        # Detecta si nc usa -p (GNU netcat) o no (OpenBSD netcat)
        local nc_opts="-u -l"
        nc --help 2>&1 | grep -q -- '-p' && nc_opts="-u -l -p"
        (while true; do
            # shellcheck disable=SC2086
            nc $nc_opts "$TELLO_STATE_PORT" 2>/dev/null \
                | while IFS= read -r line; do
                    [[ -n "$line" ]] && printf '%s\n' "$line" > "$STATE_FILE"
                  done
        done) &

    else
        echo -e "${RED}Error: se requiere 'socat', 'python3' o 'nc' (netcat).${NC}"
        exit 1
    fi
}

# ─── Keepalive: evita aterrizaje automático (límite SDK: 15 s sin comandos) ────
start_keepalive() {
    (while true; do
        sleep 10
        send_command "battery?"
    done) &
}

# ─── Verificar conectividad con el Tello ──────────────────────────────────────
check_connectivity() {
    echo -e "  ${YELLOW}Comprobando conectividad con ${TELLO_IP}...${NC}"
    if ! ping -c1 -W2 "$TELLO_IP" &>/dev/null; then
        echo -e "  ${RED}✗ No se puede alcanzar ${TELLO_IP}.${NC}"
        echo -e "  ${DIM}Conéctate a la red WiFi del Tello (TELLO-XXXXXX) e intenta de nuevo.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ Tello localizado en ${TELLO_IP}${NC}"
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
tput civis 2>/dev/null    # Ocultar cursor durante el monitor

clear
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║       TELLO MONITOR  —  SDK 2.0       ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${NC}"

check_connectivity

echo -e "  ${YELLOW}[1/3]${NC} Iniciando listener de estado (UDP :${TELLO_STATE_PORT})..."
start_state_listener
sleep 0.3

echo -e "  ${YELLOW}[2/3]${NC} Enviando 'command' al Tello (${TELLO_IP}:${TELLO_CMD_PORT})..."
send_command "command"
sleep 1.5

echo -e "  ${YELLOW}[3/3]${NC} Iniciando keepalive (cada 10 s)..."
start_keepalive

echo -e "\n  ${GREEN}¡Monitor activo! Actualizando cada ${INTERVAL} s.${NC}"
sleep 2

# ── Bucle principal de visualización ──────────────────────────────────────────
while true; do
    display_state
    sleep "$INTERVAL"
done
