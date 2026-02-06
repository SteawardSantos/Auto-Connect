#!/bin/bash

# --- CONFIGURACIÓN DE NODO ---
# CAMBIA ESTO EN CADA RASPBERRY (1, 2, 3...)
NODE_ID="1"

# --- CONFIGURACIÓN DE RED ---
VIRTUAL_IP="10.200.0.${NODE_ID}"    # La IP "Falsa" para acceder a este nodo
TARGET_REAL_IP="192.168.41.1"       # La IP real del autómata/PLC
WIFI_PASS="SN2008@+"
WIFI_IFACE="wlan0"
LAN_IFACE="eth0"
CONN_PROFILE_NAME="WIFI_SECUNDARIA_NAT"
METRIC_VALUE="600"

# --- COLORES Y LOGS ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[AVISO] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

# Verificación de root
if [ "$EUID" -ne 0 ]; then
  error "Este script requiere permisos de superusuario (sudo)."
  exit 1
fi

echo "--- Iniciando Configuración NAT (Modo Seguro) ---"
echo "Nodo ID: $NODE_ID | IP Virtual: $VIRTUAL_IP"

# 1. GESTIÓN DEL WI-FI
log "Verificando Wi-Fi..."

# Encender radio si hace falta
if [ "$(nmcli radio wifi)" != "enabled" ]; then
    warn "Radio Wi-Fi apagado. Encendiendo..."
    nmcli radio wifi on
    sleep 4
fi

# Buscar redes (Lógica simplificada para reconexión)
CURRENT_CON=$(nmcli -t -f NAME connection show --active | grep "$CONN_PROFILE_NAME")

if [ "$CURRENT_CON" == "$CONN_PROFILE_NAME" ]; then
    log "Ya estás conectado al perfil correcto. Verificando parámetros..."
    # Aún así, forzamos la actualización de la métrica por seguridad
    nmcli connection modify "$CONN_PROFILE_NAME" ipv4.route-metric "$METRIC_VALUE"
    # No hacemos 'up' para no cortar la conexión si ya está bien
else
    log "No conectado al perfil NAT. Escaneando..."
    TARGET_SSID=$(nmcli -t -f SSID device wifi list | grep "^AP[0-9]" | head -n 1)
    
    if [ -z "$TARGET_SSID" ]; then
        error "No se detectaron redes APxxxx."
        exit 1
    fi

    log "Red detectada: $TARGET_SSID. Configurando..."
    
    # Borrar perfil anterior si existe para evitar conflictos
    if nmcli connection show "$CONN_PROFILE_NAME" &> /dev/null; then
        nmcli connection delete "$CONN_PROFILE_NAME" &> /dev/null
    fi

    # Crear y conectar
    nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$CONN_PROFILE_NAME" ssid "$TARGET_SSID" \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASS" \
        ipv4.route-metric "$METRIC_VALUE" > /dev/null
        
    nmcli connection up "$CONN_PROFILE_NAME"
fi

# 2. OPTIMIZACIÓN Y SYSCTL (Sobrescritura segura)
log "Aplicando configuraciones de Kernel..."

if command -v ethtool &> /dev/null; then
    ethtool -K "$LAN_IFACE" rx-udp-gro-forwarding on rx-gro-list off &> /dev/null || true
fi

# Usamos '>' para sobrescribir el archivo completo, evitando líneas duplicadas
echo "# Configuración generada por script auto-nat" > /etc/sysctl.d/99-tailscale-nat.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-tailscale-nat.conf
echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-tailscale-nat.conf
sysctl -p /etc/sysctl.d/99-tailscale-nat.conf &> /dev/null


# 3. IP VIRTUAL (Loopback)
# Verificamos si la IP ya existe antes de añadirla para evitar errores
if ip addr show lo | grep -q "$VIRTUAL_IP"; then
    log "La IP Virtual $VIRTUAL_IP ya está asignada. Omitiendo paso."
else
    log "Asignando IP Virtual $VIRTUAL_IP a la interfaz loopback..."
    ip addr add "$VIRTUAL_IP/32" dev lo
fi

# 4. REGLAS DE FIREWALL (IPTABLES)
log "Actualizando reglas NAT..."

# Limpiamos SOLO las reglas NAT para evitar duplicados infinitos al re-correr el script
iptables -t nat -F

# Volvemos a aplicar las reglas
iptables -t nat -A PREROUTING -d "$VIRTUAL_IP" -j DNAT --to-destination "$TARGET_REAL_IP"
iptables -t nat -A POSTROUTING -d "$TARGET_REAL_IP" -j MASQUERADE

# Guardar persistencia (instalación silenciosa si falta)
if ! dpkg -s iptables-persistent &> /dev/null; then
    log "Instalando iptables-persistent..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null
fi
netfilter-persistent save &> /dev/null


# 5. TAILSCALE
log "Refrescando Tailscale..."
# --reset forza a que tome los cambios si ya estaba corriendo
tailscale up --advertise-routes="${VIRTUAL_IP}/32" --accept-routes --reset

echo ""
log "✅ Configuración Finalizada Exitosamente."
echo "-----------------------------------------------------"
echo " Nodo ID: $NODE_ID"
echo " Accede remotamente usando: $VIRTUAL_IP"
echo " Destino Real (Local):      $TARGET_REAL_IP"
echo "-----------------------------------------------------"