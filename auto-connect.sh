#!/bin/bash

# --- CONFIGURACIÓN ---
WIFI_PASS="SN2008@+"
WIFI_IFACE="wlan0"
LAN_IFACE="eth0"
CONN_PROFILE_NAME="WIFI_SECUNDARIA_AUTO"
METRIC_VALUE="600"
TS_ROUTES="192.168.41.0/24"

# Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[AVISO] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

if [ "$EUID" -ne 0 ]; then
  error "Ejecuta como root (sudo)"
  exit 1
fi

echo "--- Iniciando Auto-Conexión Inteligente ---"

# 1. WIFI RADIO
if [ "$(nmcli radio wifi)" != "enabled" ]; then
    warn "Wi-Fi apagado. Encendiendo..."
    nmcli radio wifi on
    sleep 4
else
    log "Radio Wi-Fi activo."
fi

# 2. ESCANEAR
log "Escaneando redes 'APxxxx'..."
AVAILABLE_NETWORKS=$(nmcli -t -f SSID device wifi list | grep "^AP[0-9]" | sort -u)
NUM_NETWORKS=$(echo "$AVAILABLE_NETWORKS" | grep -v "^$" | wc -l)
TARGET_SSID=""

if [ "$NUM_NETWORKS" -eq 0 ]; then
    error "No se encontraron redes 'APxxxx'."
    exit 1
elif [ "$NUM_NETWORKS" -eq 1 ]; then
    TARGET_SSID=$AVAILABLE_NETWORKS
    log "Red única: $TARGET_SSID."
else
    warn "Múltiples redes ($NUM_NETWORKS). Elige:"
    IFS=$'\n' read -rd '' -a NET_ARRAY <<< "$AVAILABLE_NETWORKS"
    select opt in "${NET_ARRAY[@]}"; do
        if [[ -n "$opt" ]]; then TARGET_SSID=$opt; break; fi
    done
    log "Seleccionada: $TARGET_SSID"
fi

# 3. CONFIGURAR CONEXIÓN
log "Configurando perfil..."
if nmcli connection show "$CONN_PROFILE_NAME" &> /dev/null; then
    nmcli connection delete "$CONN_PROFILE_NAME" &> /dev/null
fi

nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$CONN_PROFILE_NAME" ssid "$TARGET_SSID" \
    wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASS" \
    ipv4.route-metric "$METRIC_VALUE" > /dev/null

# 4. CONECTAR
log "Conectando..."
nmcli connection up "$CONN_PROFILE_NAME"

# 5. OPTIMIZACIÓN ETHTOOL
if command -v ethtool &> /dev/null; then
    log "Aplicando parche ethtool..."
    ethtool -K "$LAN_IFACE" rx-udp-gro-forwarding on rx-gro-list off &> /dev/null
fi

# 6. ACTIVAR IP FORWARDING (NUEVO - CORRIGE EL ERROR DE TAILSCALE)
log "Activando IP Forwarding para rutas..."
# Habilita IPv4 forwarding
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-tailscale.conf
# Habilita IPv6 forwarding (opcional pero recomendado)
echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.d/99-tailscale.conf
# Aplica los cambios
sysctl -p /etc/sysctl.d/99-tailscale.conf &> /dev/null

# 7. TAILSCALE
log "Levantando Tailscale..."
tailscale up --advertise-routes="$TS_ROUTES" --accept-routes

echo ""
log "¡Todo listo! Rutas activas:"
route -n | grep -E "Iface|$LAN_IFACE|$WIFI_IFACE"