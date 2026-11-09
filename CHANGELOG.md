# Historial de Versiones — BLUE COMPANY WEB

## [10.1.0] - Actualización de Estabilidad y Migración Inteligente
- Nuevo motor de actualización dinámica guiado por manifiesto `SHA256SUMS`.
- Migración automática de base de datos SQLite sin pérdida de sesiones ni configuraciones.
- Importador automático de cuentas heredadas desde `/etc/ssh-limits.txt` (sin almacenar claves en texto plano).
- Mejora en la detección en tiempo real de sesiones Dropbear y OpenSSH.
- Validación previa de certificados TLS y reinicio diferido sin corte de túneles activos.

## [10.0.0] - Lanzamiento Inicial Web (Rama: web-v10)
- Interfaz web responsive inspirada en 3X-UI con backend FastAPI y SQLite.
- Separación de privilegios mediante usuario `bluepanel` y helper restringido.
