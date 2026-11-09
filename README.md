# BLUE COMPANY WEB v10.0

Panel web corporativo inspirado en **3X-UI** para la administración integral de servidores Ubuntu (SSH, Dropbear, WebSocket Multiplexer, BadVPN UDPGW y Auto-Limitador 24/7).

## Características Principales (v10.0.0)
- **Interfaz Web Responsive (3X-UI Style):** Dashboard en tiempo real, gráficas de recursos, gestión comercial de usuarios SSH, tickets de cliente y monitor de sesiones en vivo.
- **Arquitectura Segura de Mínimo Privilegio:** Backend en **FastAPI + SQLite** ejecutándose bajo el usuario sin privilegios `bluepanel`, separado del sistema mediante `/usr/local/sbin/blue-priv-helper`.
- **Cero Contraseñas SSH en Texto Plano:** A diferencia de ediciones de terminal anteriores, las contraseñas de usuarios SSH nunca se almacenan en archivos de texto ni bases de datos.
- **Respeto Total a Servicios Externos:** Detecta en modo de solo lectura `Xray`, `3X-UI`, `Nginx`, `Hysteria 2` y `Fail2ban` sin alterarlos ni detenerlos.

## Instalación en Ubuntu Server (20.04 / 22.04 / 24.04)

```bash
git clone -b web-v10 [https://github.com/david-bluecompany/blue-company.git](https://github.com/david-bluecompany/blue-company.git) /tmp/blue-company
sudo bash /tmp/blue-company/install.sh
