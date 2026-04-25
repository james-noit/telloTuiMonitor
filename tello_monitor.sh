#!/usr/bin/env bash
# =============================================================================
# tello_monitor.sh — Monitor TUI + control de vuelo · Tello SDK 2.0
#   Comandos  : UDP 192.168.10.1:8889  (PC ↔ Tello)
#   Estado    : UDP 0.0.0.0:8890       (Tello → PC, ~10-20 Hz)
#   Navegación: ← → seleccionar  ·  Enter ejecutar  ·  q salir
# =============================================================================

# ─── Configuración ────────────────────────────────────────────────────────────
TELLO_IP="192.168.10.1"
TELLO_CMD_PORT=8889
TELLO_STATE_PORT=8890
STATE_FILE="/tmp/tello_state_$$.txt"
RESPONSE_FILE="/tmp/tello_resp_$$.txt"
INTERVAL=5          # segundos entre refresco automático del estado

# ─── Colores ANSI ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
REV='\033[7m'       # vídeo inverso (resaltar botón seleccionado)
NC='\033[0m'

# ─── Estado TUI ───────────────────────────────────────────────────────────────
SELECTED=0          # 0 = DESPEGAR   1 = ATERRIZAR
LAST_CMD="—"
LAST_RESPONSE="—"
_CLEANING=0

# ─── Guardar estado original del terminal ─────────────────────────────────────
ORIG_STTY=$(stty -g 2>/dev/null)

# ─── Limpieza al salir (Ctrl+C / kill / q) ────────────────────────────────────
cleanup() {
    (( _CLEANING )) && return
    _CLEANING=1
    [[ -n "$ORIG_STTY" ]] && stty "$ORIG_STTY" 2>/dev/null
    tput cnorm 2>/dev/null
    echo -e "\n${YELLOW}Cerrando monitor Tello...${NC}"
    jobs -p | xargs -r kill 2>/dev/null
    rm -f "$STATE_FILE" "$RESPONSE_FILE"
    echo -e "${GREEN}Fin.${NC}"
    exit 0
}
trap cleanup INT TERM EXIT

# ─── Enviar comando UDP sin esperar respuesta (keepalive) ─────────────────────
send_command() {
    echo -n "$1" > /dev/udp/"$TELLO_IP"/"$TELLO_CMD_PORT" 2>/dev/null || true
}

# ─── Enviar comando y capturar respuesta vía python3 (async) ──────────────────
# Usa puerto local 9000 (igual que Tello3.py oficial) para que el Tello
# sepa a qué puerto responder.
send_command_response() {
    local cmd="$1"
    LAST_CMD="$cmd"
    LAST_RESPONSE="enviando..."
    rm -f "$RESPONSE_FILE"
    python3 - "$cmd" "$RESPONSE_FILE" "$TELLO_IP" "$TELLO_CMD_PORT" <<'PYEOF' &
import socket, sys
cmd  = sys.argv[1].encode()
rf   = sys.argv[2]
ip   = sys.argv[3]
port = int(sys.argv[4])
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.settimeout(5)
resp = 'sin respuesta (timeout)'
try:
    sock.bind(('', 9000))
    sock.sendto(cmd, (ip, port))
    data, _ = sock.recvfrom(1024)
    resp = data.decode('utf-8', errors='ignore').strip()
except Exception as e:
    resp = str(e)[:50]
finally:
    try: sock.close()
    except: pass
with open(rf, 'w') as f:
    f.write(resp + '\n')
PYEOF
}

# ─── Inicializar SDK mode (python3, bloqueante) ───────────────────────────────
init_sdk() {
    python3 - "$TELLO_IP" "$TELLO_CMD_PORT" 2>&1 <<'PYEOF'
import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.settimeout(5)
try:
    sock.bind(('', 9000))
    sock.sendto(b'command', (sys.argv[1], int(sys.argv[2])))
    data, _ = sock.recvfrom(1024)
    print("  \u2713 SDK mode:", data.decode('utf-8', errors='ignore').strip())
except socket.timeout:
    print("  \u2717 Tello no respondio (timeout)")
except Exception as e:
    print("  \u2717 Error:", e)
finally:
    try: sock.close()
    except: pass
PYEOF
}

# ─── Listener UDP de estado en puerto 8890 ────────────────────────────────────
start_state_listener() {
    if command -v socat &>/dev/null; then
        (socat -u "UDP-RECVFROM:${TELLO_STATE_PORT},reuseaddr,fork" STDOUT 2>/dev/null \
            | while IFS= read -r line; do
                [[ -n "$line" ]] && printf '%s\n' "$line" > "$STATE_FILE"
              done) &
    elif command -v python3 &>/dev/null; then
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
        echo -e "${RED}Error: se requiere 'socat', 'python3' o 'nc'.${NC}"
        exit 1
    fi
}

# ─── Keepalive: evita aterrizaje automático (límite SDK: 15 s sin comandos) ───
start_keepalive() {
    (while true; do
        sleep 10
        send_command "battery?" 2>/dev/null
    done) &
}

# ─── Verificar conectividad ───────────────────────────────────────────────────
check_connectivity() {
    printf "  ${YELLOW}Comprobando conectividad con %s...${NC}\n" "$TELLO_IP"
    if ! ping -c1 -W2 "$TELLO_IP" &>/dev/null; then
        printf "  ${RED}No se puede alcanzar %s.${NC}\n" "$TELLO_IP"
        printf "  ${DIM}Conectate a la red WiFi del Tello (TELLO-XXXXXX) e intenta de nuevo.${NC}\n"
        exit 1
    fi
    printf "  ${GREEN}Tello localizado en %s${NC}\n" "$TELLO_IP"
}

# ─── Parsear campo del string de estado ───────────────────────────────────────
get_field() {
    echo "$1" | tr ';' '\n' | awk -F':' -v f="$2" '$1==f{print $2; exit}'
}

# ─── Barra visual de batería ──────────────────────────────────────────────────
bat_bar() {
    local val="${1:-0}"
    [[ "$val" =~ ^[0-9]+$ ]] || val=0
    local filled=$(( val / 10 )) bar=""
    for ((i=0; i<filled; i++));  do bar+="█"; done
    for ((i=filled; i<10; i++)); do bar+="░"; done
    echo "$bar"
}

# ─── Dibujar TUI completa ─────────────────────────────────────────────────────
display() {
    local ts state
    local bat="" h="" pitch="" roll="" yaw="" templ="" temph=""
    local tof="" vgx="" vgy="" vgz="" baro="" tiempo=""

    ts=$(date '+%H:%M:%S')

    # Leer respuesta pendiente del último comando
    if [[ -f "$RESPONSE_FILE" && -s "$RESPONSE_FILE" ]]; then
        LAST_RESPONSE=$(tr -d '\r\n' < "$RESPONSE_FILE")
        : > "$RESPONSE_FILE"
    fi

    # Leer último estado del dron
    if [[ -s "$STATE_FILE" ]]; then
        state=$(tail -1 "$STATE_FILE" | tr -d '\r\n')
        bat=$(get_field   "$state" "bat");   h=$(get_field     "$state" "h")
        pitch=$(get_field "$state" "pitch"); roll=$(get_field  "$state" "roll")
        yaw=$(get_field   "$state" "yaw");   templ=$(get_field "$state" "templ")
        temph=$(get_field "$state" "temph"); tof=$(get_field   "$state" "tof")
        vgx=$(get_field   "$state" "vgx");   vgy=$(get_field   "$state" "vgy")
        vgz=$(get_field   "$state" "vgz");   baro=$(get_field  "$state" "baro")
        tiempo=$(get_field "$state" "time")
    fi

    # Color de batería
    local bat_color="$GREEN" bat_num="${bat:-0}"
    [[ "$bat_num" =~ ^[0-9]+$ ]] || bat_num=0
    (( bat_num < 20 )) && bat_color="$RED"
    (( bat_num >= 20 && bat_num < 50 )) && bat_color="$YELLOW"
    local bar; bar=$(bat_bar "$bat_num")

    # Color de la respuesta
    local rc="$NC"
    [[ "$LAST_RESPONSE" == "ok" ]]         && rc="${GREEN}${BOLD}"
    [[ "$LAST_RESPONSE" == "error" ]]      && rc="${RED}${BOLD}"
    [[ "$LAST_RESPONSE" == *"timeout"* ]]  && rc="${YELLOW}${BOLD}"
    [[ "$LAST_RESPONSE" == "enviando"* ]]  && rc="${YELLOW}"

    # Botones: el seleccionado aparece en vídeo inverso
    local b0 b1
    if (( SELECTED == 0 )); then
        b0="${REV}${BOLD}  ↑ DESPEGAR  ${NC}"
        b1="${DIM}     ATERRIZAR ↓${NC}"
    else
        b0="${DIM}  ↑ DESPEGAR  ${NC}"
        b1="${REV}${BOLD}    ATERRIZAR ↓${NC}"
    fi

    # ── Dibujar ───────────────────────────────────────────────────────────────
    clear
    printf "\n"
    printf "  ${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "  ${CYAN}${BOLD}   TELLO MONITOR  ·  SDK 2.0  ·  %s${NC}\n" "$ts"
    printf "  ${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "\n"

    # Estado del dron
    if [[ -z "${state:-}" ]]; then
        printf "  ${YELLOW}Esperando datos del Tello...${NC}\n"
        printf "  ${DIM}Conectado a la red WiFi TELLO-XXXXXX?${NC}\n"
    else
        printf "  ${BOLD}Bateria   :${NC}  ${bat_color}${BOLD}%3s%%${NC}  ${bat_color}%s${NC}\n" \
               "${bat:-?}" "$bar"
        printf "  ${BOLD}Altura    :${NC}  %s cm\n"         "${h:-?}"
        printf "  ${BOLD}Dist. ToF :${NC}  %s cm\n"         "${tof:-?}"
        printf "  ${BOLD}Barometro :${NC}  %s cm\n"         "${baro:-?}"
        printf "\n"
        printf "  ${BOLD}${BLUE}Actitud  ${NC}  Pitch: ${BOLD}%4s${NC}  Roll: ${BOLD}%4s${NC}  Yaw: ${BOLD}%4s${NC}\n" \
               "${pitch:-?}" "${roll:-?}" "${yaw:-?}"
        printf "  ${BOLD}${BLUE}Velocidad${NC}  Vx: ${BOLD}%4s${NC}  Vy: ${BOLD}%4s${NC}  Vz: ${BOLD}%4s${NC} cm/s\n" \
               "${vgx:-?}" "${vgy:-?}" "${vgz:-?}"
        printf "  ${BOLD}Temp      :${NC}  %s C - %s C   Motor: %s s\n" \
               "${templ:-?}" "${temph:-?}" "${tiempo:-?}"
    fi

    printf "\n"

    # ── Panel de control ──────────────────────────────────────────────────────
    printf "  ${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "  ${BOLD}  CONTROL${NC}  ${DIM}← → navegar  ·  Enter ejecutar  ·  q salir${NC}\n"
    printf "\n"
    printf "      %b         %b\n" "$b0" "$b1"
    printf "\n"
    printf "  ${BOLD}Ultimo   :${NC}  %-20s\n" "$LAST_CMD"
    printf "  ${BOLD}Respuesta:${NC}  ${rc}%s${NC}\n" "$LAST_RESPONSE"
    printf "\n"
    printf "  ${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "  ${DIM}Estado: actualizacion automatica cada %ds${NC}\n" "$INTERVAL"
}

# ─── Leer tecla con soporte de secuencias de escape (flechas) ─────────────────
read_key() {
    local k1="" k2="" k3="" status=1

    # En modo raw + read -n, Enter puede llegar como lectura vacía con status 0.
    IFS= read -r -s -t 0.15 -n 1 k1 2>/dev/null
    status=$?
    (( status != 0 )) && return 1

    if [[ -z "$k1" ]]; then
        printf '__ENTER__'
        return 0
    fi

    if [[ "$k1" == $'\e' ]]; then
        IFS= read -r -s -t 0.05 -n 1 k2 2>/dev/null || true
        IFS= read -r -s -t 0.05 -n 1 k3 2>/dev/null || true
    fi
    printf '%s' "${k1}${k2}${k3}"
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
clear
printf "\n"
printf "  ${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${CYAN}${BOLD}     TELLO MONITOR  ·  SDK 2.0${NC}\n"
printf "  ${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "\n"

check_connectivity

printf "  ${YELLOW}[1/3]${NC} Iniciando listener de estado (UDP :%d)...\n" "$TELLO_STATE_PORT"
start_state_listener
sleep 0.3

printf "  ${YELLOW}[2/3]${NC} Activando SDK mode en Tello...\n"
init_sdk
sleep 0.5

printf "  ${YELLOW}[3/3]${NC} Iniciando keepalive (cada 10 s)...\n"
start_keepalive
sleep 1

# Activar modo raw del terminal (sin eco, sin buffer de línea)
stty -echo -icanon min 0 time 0 2>/dev/null
tput civis 2>/dev/null      # Ocultar cursor

display      # Primer dibujo

# ─── Bucle principal ──────────────────────────────────────────────────────────
NEXT_REFRESH=$(( $(date +%s) + INTERVAL ))

while true; do
    key=$(read_key)

    case "$key" in
        $'\e[D')                    # ← flecha izquierda
            SELECTED=$(( (SELECTED - 1 + 2) % 2 ))
            display
            NEXT_REFRESH=$(( $(date +%s) + INTERVAL ))
            ;;
        $'\e[C')                    # → flecha derecha
            SELECTED=$(( (SELECTED + 1) % 2 ))
            display
            NEXT_REFRESH=$(( $(date +%s) + INTERVAL ))
            ;;
        '__ENTER__'|$'\n'|$'\r')     # Enter: ejecutar opción seleccionada
            case $SELECTED in
                0) send_command_response "takeoff" ;;
                1) send_command_response "land"    ;;
            esac
            display
            NEXT_REFRESH=$(( $(date +%s) + INTERVAL ))
            ;;
        'q'|'Q')                    # q: salir
            cleanup
            ;;
    esac

    # Redibujar si llegó una respuesta nueva o si expiró el intervalo
    NOW=$(date +%s)
    if [[ -f "$RESPONSE_FILE" && -s "$RESPONSE_FILE" ]] || (( NOW >= NEXT_REFRESH )); then
        display
        NEXT_REFRESH=$(( NOW + INTERVAL ))
    fi
done
