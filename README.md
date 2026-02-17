# Auto-Connect Wi-Fi & Tailscale Bridge 🚀

Este repositorio contiene un conjunto de scripts diseñados para automatizar la configuración de Raspberry Pi como **Tailscale Bridges**, con una lógica de auto-descubrimiento basada en la red Tailscale.

## 📋 Características principales

*   **Auto-Discovery de NODE_ID:** Asigna automáticamente un `NODE_ID` único (del 1 al 254) basado en la posición alfabética del hostname del nodo (`*-rpi-pt`) en la red Tailscale.
*   **Gestión Wi-Fi Inteligente:** Busca y conecta automáticamente a redes Wi-Fi con el patrón `APxxxx`.
*   **Prioridad de LAN:** Configura métricas de ruta (`600`) para que la conexión Ethernet mantenga la prioridad sobre el Wi-Fi.
*   **Bridge NAT Automático:** Configura reglas de `iptables` y redirección de puertos para mapear IPs virtuales (`10.200.0.X`) a la IP local del dispositivo (`192.168.41.1`).
*   **Auto-Aprobación de Rutas:** Diseñado para funcionar con ACLs de Tailscale que aprueban automáticamente el rango `10.200.0.0/24`.

## 🛠️ Scripts incluidos

### 1. `auto-connect.sh`
El script principal. Ejecútalo en cada Raspberry Pi para:
- Detectar su posición alfabética y asignar su ID.
- Configurar la IP virtual en el loopback.
- Establecer la conexión Wi-Fi de respaldo.
- Configurar NAT y persistencia de firewall.
- Anunciar la ruta en Tailscale.

```bash
sudo ./auto-connect.sh
```

### 2. `diagnose-tailscale.sh`
Herramienta de diagnóstico para verificar el estado de Tailscale, las rutas anunciadas y la configuración local.

```bash
sudo ./diagnose-tailscale.sh
```

### 3. `generate-report.sh`
Genera un reporte consolidado en CSV de todos los nodos activos en la red, sus IPs de Tailscale y sus IPs virtuales correspondientes.

```bash
./generate-report.sh
```

## ⚙️ Configuración predeterminada

*   **Rango Virtual:** `10.200.0.X/32`
*   **Destino Real:** `192.168.41.1`
*   **Interfaz LAN:** `eth0`
*   **Interfaz Wi-Fi:** `wlan0`
*   **Patrón de SSID:** `AP[0-9]`

## 📄 Licencia

Este proyecto está bajo la Licencia MIT.
