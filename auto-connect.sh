#!/bin/bash

# ==========================================
#      CONFIGURACIÓN DEL NODO (EDITAR)
# ==========================================
# Cambia este ID en cada Raspberry (1, 2, 3...)
NODE_ID="1" 

# ==========================================
#           VARIABLES DEL SISTEMA
# ==========================================
VIRTUAL_IP="10.200.0.${NODE_ID}"    # IP Fantasma para acceder a este nodo
TARGET_REAL_IP="192.168.41.1"       # IP Real del dispositivo local
WIFI_PASS="SN2008@+"                # Contraseña del AP
WIFI_IFACE="wlan0"
LAN_IFACE="eth0"
CONN_PROFILE_NAME="WIFI_SECUNDARIA_NAT"
METRIC_VALUE="600"                  # 600 = Prioridad baja (Protege LAN)

# ==========================================
#               FUNCIONES
# ==========================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[AVISO] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

if [ "$EUID" -ne 0 ]; then
  error "Este script requiere sudo."
  exit 1
fi

echo "--- Iniciando Configuración Automática (v7 - DNS Fix) ---"
echo "Nodo: $NODE_ID | IP Virtual: $VIRTUAL_IP"

# ------------------------------------------
# 1. GESTIÓN INTELIGENTE DEL WI-FI
# ------------------------------------------
log "Verificando conectividad Wi-Fi..."

# Encender radio si está apagado
if [ "$(nmcli radio wifi)" != "enabled" ]; then
    warn "Radio Wi-Fi apagado. Encendiendo..."
    nmcli radio wifi on
    sleep 4
fi

# Verificar si ya estamos conectados al perfil correcto
CURRENT_CON=$(nmcli -t -f NAME connection show --active | grep "$CONN_PROFILE_NAME")

if [ "$CURRENT_CON" == "$CONN_PROFILE_NAME" ]; then
    log "Conexión Wi-Fi correcta detectada. Asegurando métrica..."
    nmcli connection modify "$CONN_PROFILE_NAME" ipv4.route-metric "$METRIC_VALUE"
else
    log "Buscando red APxxxx..."
    # Busca la primera red que cumpla el patrón
    TARGET_SSID=$(nmcli -t -f SSID device wifi list | grep "^AP[0-9]" | head -n 1)
    
    if [ -z "$TARGET_SSID" ]; then
        error "No se encontraron redes compatibles."
        exit 1
    fi

    log "Red encontrada: $TARGET_SSID. Configurando..."
    
    # Limpieza preventiva
    if nmcli connection show "$CONN_PROFILE_NAME" &> /dev/null; then
        nmcli connection delete "$CONN_PROFILE_NAME" &> /dev/null
    fi

    # Crear conexión segura
    nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$CONN_PROFILE_NAME" ssid "$TARGET_SSID" \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASS" \
        ipv4.route-metric "$METRIC_VALUE" > /dev/null
        
    nmcli connection up "$CONN_PROFILE_NAME"
fi

# ------------------------------------------
# 2. OPTIMIZACIÓN Y KERNEL (Idempotente)
# ------------------------------------------
log "Aplicando parches de kernel..."

# Optimización Ethtool
if command -v ethtool &> /dev/null; then
    ethtool -K "$LAN_IFACE" rx-udp-gro-forwarding on rx-gro-list off &> /dev/null || true
fi

# IP Forwarding (Sobrescritura limpia)
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-tailscale-nat.conf
echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-tailscale-nat.conf
sysctl -p /etc/sysctl.d/99-tailscale-nat.conf &> /dev/null

# ------------------------------------------
# 3. IP VIRTUAL (Loopback)
# ------------------------------------------
if ip addr show lo | grep -q "$VIRTUAL_IP"; then
    log "IP Virtual ya configurada."
else
    log "Asignando IP Virtual $VIRTUAL_IP..."
    ip addr add "$VIRTUAL_IP/32" dev lo
fi

# ------------------------------------------
# 4. FIREWALL & DNS CHECK
# ------------------------------------------
log "Configurando reglas NAT..."

# Limpieza de reglas NAT previas
iptables -t nat -F

# Reglas de redirección
iptables -t nat -A PREROUTING -d "$VIRTUAL_IP" -j DNAT --to-destination "$TARGET_REAL_IP"
iptables -t nat -A POSTROUTING -d "$TARGET_REAL_IP" -j MASQUERADE

# Persistencia de reglas
if ! dpkg -s iptables-persistent &> /dev/null; then
    log "El paquete 'iptables-persistent' falta. Intentando instalar..."
    
    # TRUCO: Si el DNS está roto por Tailscale, intentamos arreglarlo temporalmente para el apt-get
    if ! ping -c 1 google.com &> /dev/null; then
        warn "DNS parece roto. Usando parche temporal 8.8.8.8..."
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
    fi
    
    DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null
fi
netfilter-persistent save &> /dev/null

# ------------------------------------------
# 5. TAILSCALE (CON FIX DE DNS)
# ------------------------------------------
log "Aplicando configuración final de Tailscale..."

# AQUI ESTA EL FIX: --accept-dns=false
# Esto evita que Tailscale rompa la resolución de nombres local/internet
tailscale up \
    --advertise-routes="${VIRTUAL_IP}/32" \
    --accept-routes \
    --accept-dns=false \
    --reset

echo ""
log "✅ INSTALACIÓN COMPLETADA CORRECTAMENTE"
echo "-----------------------------------------------------"
echo " 📡 Nodo ID:         $NODE_ID"
echo " 🔗 IP de Acceso:    $VIRTUAL_IP"
echo " 🎯 Destino Real:    $TARGET_REAL_IP"
echo " 🌍 DNS Fix:         ACTIVADO (--accept-dns=false)"
echo "-----------------------------------------------------"