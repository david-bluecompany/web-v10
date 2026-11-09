#!/bin/bash
# ==============================================================================
# BLUE COMPANY WEB v10.1 — Privileged Operations Helper
# Ejecutado vía sudo restringido por el usuario de sistema 'bluepanel'
# ==============================================================================
set -euo pipefail
export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

DB_FILE="/etc/bluecompany/bluecompany.db"
SCRIPTS_DIR="/opt/blue-company/scripts"
MANAGED_TAG="BLUECOMPANY_MANAGED"

validar_usuario() {
    local u="$1"
    [[ "$u" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || { echo "ERROR: Nombre de usuario inválido"; exit 1; }
    if [[ "$u" =~ ^(root|ubuntu|debian|admin|bluepanel|sshd|systemd-.*|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|nobody)$ ]]; then
        echo "ERROR: Usuario reservado del sistema protegido"
        exit 1
    fi
    # Proteger usuarios con privilegios sudo/admin en el VPS
    if id -nG "$u" 2>/dev/null | grep -qwE '(sudo|wheel|adm|root|bluecompany)'; then
        echo "ERROR: No se permite modificar cuentas administrativas del VPS"
        exit 1
    fi
}

es_usuario_administrado() {
    local u="$1"
    validar_usuario "$u"
    local passwd_entry uid gecos
    passwd_entry=$(getent passwd "$u" || true)
    [ -z "$passwd_entry" ] && return 1
    uid=$(echo "$passwd_entry" | cut -d: -f3)
    gecos=$(echo "$passwd_entry" | cut -d: -f5)
    [ "${uid:-0}" -lt 1000 ] && return 1
    [[ "$gecos" == *"$MANAGED_TAG"* ]] || return 1

    if [ -f "$DB_FILE" ] && command -v sqlite3 &>/dev/null; then
        local existe
        existe=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM ssh_users WHERE username='$u';" 2>/dev/null || echo "0")
        [ "$existe" -gt 0 ] && return 0
    fi
    return 1
}

obtener_mapa_dropbear() {
    python3 - << 'PYEOF'
import os, re, subprocess
cache_file = "/run/blue-dropbear.map"
all_pids = []
for entry in os.listdir("/proc"):
    if entry.isdigit():
        try:
            comm = open(f"/proc/{entry}/comm", "r").read().strip().lower()
            stat_ppid = int(open(f"/proc/{entry}/stat", "r").read().rsplit(")", 1)[-1].split()[1])
            if "dropbear" in comm and stat_ppid > 1:
                all_pids.append(entry)
        except Exception:
            pass
if not all_pids:
    raise SystemExit(0)
mapped = {}
if os.path.exists(cache_file):
    try:
        with open(cache_file, "r", errors="ignore") as cf:
            for line in cf:
                if ":" in line:
                    p, usr = line.strip().split(":", 1)
                    if p in all_pids:
                        mapped[p] = usr
    except Exception:
        pass
if len(mapped) < len(all_pids):
    log_text = ""
    for lf in ["/var/log/auth.log", "/var/log/syslog", "/var/log/secure"]:
        if os.path.exists(lf):
            try:
                with open(lf, "r", errors="ignore") as f:
                    f.seek(0, os.SEEK_END)
                    sz = f.tell()
                    f.seek(max(0, sz - 200000))
                    log_text += f.read() + "\n"
            except Exception:
                pass
    try:
        log_text += subprocess.check_output(["journalctl", "-u", "dropbear", "--no-pager", "-n", "600"], stderr=subprocess.DEVNULL).decode(errors="ignore")
    except Exception:
        pass
    pat = re.compile(r"dropbear\[(\d+)\]:.*succeeded for ['\"]?([^'\"\s]+)['\"]?", re.IGNORECASE)
    for m in pat.finditer(log_text):
        if m.group(1) in all_pids:
            mapped[m.group(1)] = m.group(2)
for pid, usr in mapped.items():
    print(f"{pid}:{usr}")
PYEOF
}

expulsar_usuario() {
    local u="$1"
    es_usuario_administrado "$u" || { echo "ERROR: Usuario no administrado por BLUE COMPANY"; exit 1; }
    pkill -KILL -u "$u" 2>/dev/null || true
    ps -eo pid=,user=,args= 2>/dev/null | awk -v usr="$u" '$2=="root" && $0 ~ "sshd(-session)?: " usr "(\\[|@|$)" {print $1}' | xargs -r kill -9 2>/dev/null || true
    local mapa_db
    mapa_db=$(obtener_mapa_dropbear || true)
    if [ -n "$mapa_db" ]; then
        local pids_db
        pids_db=$(printf "%s\n" "$mapa_db" | awk -F':' -v usr="$u" '$2 == usr {print $1}')
        for p in $pids_db; do
            [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ] && kill -9 "$p" 2>/dev/null || true
        done
    fi
}

accion="${1:-}"
shift || true

case "$accion" in
    user-create)
        usuario="${1:-}"
        exp_epoch="${2:-}"
        validar_usuario "$usuario"
        [[ "$exp_epoch" =~ ^[0-9]+$ ]] || { echo "ERROR: Epoch inválido"; exit 1; }
        if id "$usuario" &>/dev/null; then
            echo "ERROR: El usuario ya existe en el sistema"
            exit 1
        fi
        read -r clave
        f_chage=$(date -d "@$(( exp_epoch + 86400 ))" +%Y-%m-%d)
        for sh_path in "/bin/false" "/usr/sbin/nologin"; do
            [ -f "$sh_path" ] && ! grep -qxF "$sh_path" /etc/shells 2>/dev/null && echo "$sh_path" >> /etc/shells
        done
        useradd -M -s /bin/false -c "$MANAGED_TAG" -e "$f_chage" "$usuario"
        echo "${usuario}:${clave}" | chpasswd
        echo "OK"
        ;;

    user-password)
        usuario="${1:-}"
        es_usuario_administrado "$usuario" || { echo "ERROR: Usuario no administrado por BLUE COMPANY"; exit 1; }
        read -r nueva_clave
        echo "${usuario}:${nueva_clave}" | chpasswd
        echo "OK"
        ;;

    user-expiry)
        usuario="${1:-}"
        exp_epoch="${2:-}"
        es_usuario_administrado "$usuario" || { echo "ERROR: Usuario no administrado por BLUE COMPANY"; exit 1; }
        [[ "$exp_epoch" =~ ^[0-9]+$ ]] || { echo "ERROR: Epoch inválido"; exit 1; }
        f_chage=$(date -d "@$(( exp_epoch + 86400 ))" +%Y-%m-%d)
        usermod -e "$f_chage" "$usuario"
        echo "OK"
        ;;

    user-lock)
        usuario="${1:-}"
        es_usuario_administrado "$usuario" || { echo "ERROR: Usuario no administrado por BLUE COMPANY"; exit 1; }
        expulsar_usuario "$usuario"
        usermod -L -s /bin/expired -e 1970-01-02 "$usuario" 2>/dev/null || true
        passwd -l "$usuario" &>/dev/null || true
        echo "OK"
        ;;

    user-unlock)
        usuario="${1:-}"
        exp_epoch="${2:-}"
        es_usuario_administrado "$usuario" || { echo "ERROR: Usuario no administrado por BLUE COMPANY"; exit 1; }
        [[ "$exp_epoch" =~ ^[0-9]+$ ]] || { echo "ERROR: Epoch inválido"; exit 1; }
        f_chage=$(date -d "@$(( exp_epoch + 86400 ))" +%Y-%m-%d)
        usermod -U -s /bin/false -e "$f_chage" "$usuario" 2>/dev/null || true
        passwd -u "$usuario" &>/dev/null || true
        echo "OK"
        ;;

    user-kick)
        usuario="${1:-}"
        expulsar_usuario "$usuario"
        echo "OK"
        ;;

    user-delete)
        usuario="${1:-}"
        es_usuario_administrado "$usuario" || { echo "ERROR: Usuario no administrado por BLUE COMPANY"; exit 1; }
        expulsar_usuario "$usuario"
        userdel -rf "$usuario" 2>/dev/null || true
        echo "OK"
        ;;

    live-telemetry)
        python3 - << 'PYEOF'
import os, json, re, subprocess

db_map = {}
cache_file = "/run/blue-dropbear.map"
if os.path.exists(cache_file):
    try:
        with open(cache_file, "r") as f:
            for line in f:
                if ":" in line:
                    p, u = line.strip().split(":", 1)
                    db_map[p] = u
    except Exception:
        pass

managed_users = set()
uid_map = {}
with open("/etc/passwd", "r", errors="ignore") as pf:
    for line in pf:
        parts = line.strip().split(":")
        if len(parts) >= 5:
            uid_map[parts[2]] = parts[0]
            if "BLUECOMPANY_MANAGED" in parts[4]:
                managed_users.add(parts[0])

ss_out = ""
try:
    ss_out = subprocess.check_output(["ss", "-tnp"], stderr=subprocess.DEVNULL).decode(errors="ignore")
except Exception:
    pass

user_sessions = {}
for pid in os.listdir("/proc"):
    if not pid.isdigit():
        continue
    try:
        comm = open(f"/proc/{pid}/comm", "r").read().strip().lower()
        stat_ppid = int(open(f"/proc/{pid}/stat", "r").read().rsplit(")", 1)[-1].split()[1])
        if stat_ppid <= 1:
            continue
        usr = None
        proto = "SSH"
        if "dropbear" in comm:
            usr = db_map.get(pid)
            proto = "Dropbear/WS"
        elif comm.startswith("sshd"):
            for sline in open(f"/proc/{pid}/status", "r"):
                if sline.startswith("Uid:"):
                    ruid = sline.split()[1]
                    if ruid != "0" and ruid in uid_map:
                        usr = uid_map[ruid]
                    break
            if not usr:
                cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\x00", b" ").decode("latin1", errors="ignore")
                m = re.search(r"sshd(?:-session)?:\s+([a-zA-Z0-9_-]+)(?:@|\[notty\]|$)", cmd)
                if m and m.group(1) != "root":
                    usr = m.group(1)
        if not usr or usr not in managed_users:
            continue
        bytes_rw = 0
        if os.path.exists(f"/proc/{pid}/io"):
            for iline in open(f"/proc/{pid}/io", "r"):
                if iline.startswith(("rchar:", "wchar:")):
                    bytes_rw += int(iline.split()[1])
        etime = subprocess.check_output(["ps", "-p", pid, "-o", "etime="], stderr=subprocess.DEVNULL).decode().strip()
        ip_cli = "WS-Tunnel (P:80)"
        for sline in ss_out.splitlines():
            if f"pid={pid}," in sline:
                cols = sline.split()
                if len(cols) >= 5:
                    peer = cols[4].replace("::ffff:", "").rsplit(":", 1)[0]
                    if not peer.startswith("127."):
                        ip_cli = peer
                        break
        info = user_sessions.setdefault(usr, {"count": 0, "bytes": 0, "ip": ip_cli, "etime": etime, "proto": proto})
        info["count"] += 1
        info["bytes"] += bytes_rw
        if info["ip"].startswith("WS-Tunnel") and not ip_cli.startswith("WS-Tunnel"):
            info["ip"] = ip_cli
    except Exception:
        continue

print(json.dumps(user_sessions))
PYEOF
        ;;

    service-action)
        srv="${1:-}"
        op="${2:-}"
        [[ "$srv" =~ ^(ssh|dropbear|despachador|badvpn|blue-limiter)$ ]] || { echo "ERROR: Servicio no permitido (servicios externos como 3X-UI/Xray están protegidos)"; exit 1; }
        [[ "$op" =~ ^(start|stop|restart)$ ]] || { echo "ERROR: Operación inválida"; exit 1; }
        if [ "$srv" = "ssh" ] && [ "$op" = "stop" ]; then
            echo "ERROR: Por seguridad no se permite detener OpenSSH"
            exit 1
        fi
        systemctl "$op" "$srv" 2>/dev/null || systemctl "$op" sshd 2>/dev/null
        echo "OK"
        ;;

    install-module)
        mod="${1:-}"
        case "$mod" in
            dropbear) bash "${SCRIPTS_DIR}/install-dropbear.sh" --non-interactive ;;
            despachador) bash "${SCRIPTS_DIR}/install-despachador.sh" --non-interactive ;;
            badvpn) bash "${SCRIPTS_DIR}/install-badvpn.sh" --non-interactive ;;
            limiter) bash "${SCRIPTS_DIR}/install-limiter.sh" --non-interactive ;;
            bbr)
                modprobe tcp_bbr 2>/dev/null || true
                modprobe sch_fq 2>/dev/null || true
                cat << 'SYSEOF' > /etc/sysctl.d/99-bluecompany-tcp.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 32768
SYSEOF
                sysctl --system &>/dev/null || true
                echo "OK: TCP BBR activado"
                ;;
            *) echo "ERROR: Módulo desconocido"; exit 1 ;;
        esac
        ;;

    diagnose)
        python3 - << 'PYEOF'
import json, subprocess, os

issues = []
def is_enabled_or_present(unit):
    return os.path.exists(f"/etc/systemd/system/{unit}.service")

def is_active(unit, proc=None):
    if subprocess.call(["systemctl", "is-active", "--quiet", unit]) == 0:
        return True
    if proc and subprocess.call(["pgrep", "-f", proc], stdout=subprocess.DEVNULL) == 0:
        return True
    return False

if is_enabled_or_present("dropbear") and not is_active("dropbear", "dropbear"):
    issues.append({"code": "START_DROPBEAR", "msg": "El servicio Dropbear (Puerto 2222) está instalado pero detenido."})
if is_enabled_or_present("despachador") and not is_active("despachador", "despachador.py"):
    issues.append({"code": "START_DESPACHADOR", "msg": "El Despachador Multiplexor WS (Puerto 80) está instalado pero detenido."})
if is_enabled_or_present("badvpn") and not is_active("badvpn", "badvpn-udpgw"):
    issues.append({"code": "START_BADVPN", "msg": "El servicio BadVPN UDPGW (Puerto 7300) está instalado pero detenido."})
if is_enabled_or_present("blue-limiter") and not is_active("blue-limiter", "blue-limiter.py"):
    issues.append({"code": "START_LIMITER", "msg": "El demonio Auto-Limitador 24/7 está instalado pero detenido."})

shells = open("/etc/shells", "r").read().splitlines() if os.path.exists("/etc/shells") else []
if "/bin/false" not in shells or "/bin/expired" in shells:
    issues.append({"code": "FIX_SHELLS", "msg": "Anomalía en /etc/shells (/bin/false ausente o /bin/expired presente)."})

print(json.dumps({"healthy": len(issues) == 0, "issues": issues}))
PYEOF
        ;;

    repair)
        [ -f /etc/systemd/system/dropbear.service ] && { pgrep -x "dropbear" &>/dev/null || systemctl start dropbear 2>/dev/null || true; }
        [ -f /etc/systemd/system/despachador.service ] && { systemctl is-active --quiet despachador 2>/dev/null || systemctl start despachador 2>/dev/null || true; }
        [ -f /etc/systemd/system/badvpn.service ] && { pgrep -f "badvpn-udpgw" &>/dev/null || systemctl start badvpn 2>/dev/null || true; }
        [ -f /etc/systemd/system/blue-limiter.service ] && { systemctl is-active --quiet blue-limiter 2>/dev/null || systemctl start blue-limiter 2>/dev/null || true; }
        for sh_path in "/bin/false" "/usr/sbin/nologin"; do
            [ -f "$sh_path" ] && ! grep -qxF "$sh_path" /etc/shells 2>/dev/null && echo "$sh_path" >> /etc/shells
        done
        sed -i '\|/bin/expired|d' /etc/shells 2>/dev/null || true
        echo "OK"
        ;;

    ports-list)
        ss -tulnp 2>/dev/null | awk 'NR>1 {
            proto = $1; split($5, a, ":"); port = a[length(a)]; proc = $7
            gsub(/users:\(\("/, "", proc); gsub(/".*/, "", proc)
            if (proc == "") proc = "kernel/sistema"
            origen = (port ~ /^(2222|7300|8443)$/ || proc ~ /despachador|dropbear|badvpn|blue-limiter/) ? "BLUE COMPANY" : "EXTERNO / SISTEMA (Protegido)"
            printf "%s|%s|%s|%s\n", proto, port, proc, origen
        }' | sort -u
        ;;

    auth-logs)
        log_f="/var/log/auth.log"
        [ ! -f "$log_f" ] && log_f="/var/log/secure"
        if [ -f "$log_f" ]; then
            tail -n 30 "$log_f" | grep -iE "sshd|dropbear|failed|accepted" | sed -E 's/password for .*/password [REDACTED]/gi' || true
        fi
        ;;

    run-update)
        bash /opt/blue-company/update.sh --non-interactive
        ;;

    *)
        echo "ERROR: Acción no autorizada"
        exit 1
        ;;
esac
