#!/bin/bash

# ==========================================
#   DIAGNÓSTICO DE TAILSCALE Y AUTO-DISCOVERY
# ==========================================

echo "========================================"
echo "  Diagnóstico de Tailscale"
echo "========================================"
echo ""

echo "1. ESTADO DE TAILSCALE"
echo "----------------------------------------"
tailscale status
echo ""

echo "2. ESTADO JSON (búsqueda de rutas)"
echo "----------------------------------------"
tailscale status --json | grep -i "route" | head -20
echo ""

echo "3. BÚSQUEDA ESPECÍFICA DE IPs 10.200.0.X"
echo "----------------------------------------"
echo "Método 1 (JSON):"
tailscale status --json 2>/dev/null | grep -oP "10\.200\.0\.\d+" | sort -u
echo ""
echo "Método 2 (texto plano):"
tailscale status 2>/dev/null | grep -oP "10\.200\.0\.\d+" | sort -u
echo ""

echo "4. OUTPUT COMPLETO DE TAILSCALE STATUS --JSON"
echo "----------------------------------------"
tailscale status --json 2>/dev/null | jq . 2>/dev/null || tailscale status --json
echo ""

echo "5. PEERS Y SUS RUTAS ANUNCIADAS"
echo "----------------------------------------"
tailscale status --json 2>/dev/null | jq -r '.Peer[] | "\(.HostName): \(.AdvertisedRoutes // [])"' 2>/dev/null || echo "jq no disponible"
echo ""

echo "6. ARCHIVO DE CONFIGURACIÓN LOCAL"
echo "----------------------------------------"
if [ -f /etc/tailscale-bridge.conf ]; then
    echo "Existe: /etc/tailscale-bridge.conf"
    cat /etc/tailscale-bridge.conf
else
    echo "NO existe: /etc/tailscale-bridge.conf"
fi
echo ""

echo "7. IP VIRTUAL EN LOOPBACK"
echo "----------------------------------------"
ip addr show lo | grep "10.200.0"
echo ""

echo "8. INFORMACIÓN DEL DISPOSITIVO"
echo "----------------------------------------"
echo "Hostname: $(hostname)"
echo "Tailscale IP: $(tailscale ip -4 2>/dev/null)"
echo ""

echo "========================================"
echo "  Diagnóstico completado"
echo "========================================"
