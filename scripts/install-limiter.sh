#!/bin/bash
# ==============================================================================
# BLUE COMPANY WEB v10.1 — Auto-Limitador 24/7 con Aislamiento Estricto
# Actúa EXCLUSIVAMENTE sobre cuentas creadas por BLUE COMPANY (GECOS + SQLite)
# Nunca toca root, cuentas sudo/admin, ni procesos de 3X-UI / Xray / V2Ray
# ==============================================================================
set -euo pipefail
export LC_ALL=C

cat << 'LIM_EOF' > /usr/local/bin/blue-limiter.py
#!/usr/bin/env python3
import os, re, grp, pwd, time, fcntl, signal, sqlite3, subprocess
from datetime import datetime

DB_SQLITE = "/etc/bluecompany/bluecompany.db"
CACHE_FILE = "/run/blue-dropbear.map"
LOCK_FILE = "/run/blue-limiter-daemon.lock"
MANAGED_TAG = "BLUECOMPANY_MANAGED"
PROTECTED_USERS = {
    "root", "ubuntu", "debian", "admin", "bluepanel", "sshd",
    "www-data", "nobody", "daemon", "syslog"
}
PROTECTED_GROUPS = {"sudo", "wheel", "adm", "root", "bluecompany", "docker"}
pid_memory = {}

def obtener_usuarios_sistema_administrados():
    """Devuelve el conjunto de usuarios Linux que poseen explícitamente GECOS BLUECOMPANY_MANAGED y UID >= 1000."""
    protegidos_por_grupo = set(PROTECTED_USERS)
    for gname in PROTECTED_GROUPS:
        try:
            g = grp.getgrnam(gname)
            protegidos_por_grupo.update(g.gr_mem)
        except KeyError:
            pass

    administrados = {}
    for p in pwd.getpwall():
        u = p.pw_name
        if u in protegidos_por_grupo or p.pw_uid < 1000:
            continue
        if MANAGED_TAG in (p.pw_gecos or ""):
            administrados[u] = {
                "uid": str(p.pw_uid),
                "shell": p.pw_shell
            }
    return administrados

def registrar_evento_db(u, motivo, nuevo_estado=None):
    if not os.path.exists(DB_SQLITE):
        return
    ahora_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        conn = sqlite3.connect(DB_SQLITE, timeout=5)
        cur = conn.cursor()
        cur.execute("INSERT INTO lock_events (timestamp, username, reason) VALUES (?, ?, ?)", (ahora_str, u, motivo))
        if nuevo_estado:
            cur.execute("UPDATE ssh_users SET status = ? WHERE username = ?", (nuevo_estado, u))
        conn.commit()
        conn.close()
    except Exception:
        pass

def leer_usuarios_autorizados():
    """Cruza la base de datos SQLite con las cuentas etiquetadas con BLUECOMPANY_MANAGED en /etc/passwd."""
    usuarios = {}
    if not os.path.exists(DB_SQLITE):
        return usuarios
    sys_managed = obtener_usuarios_sistema_administrados()
    if not sys_managed:
        return usuarios
    try:
        conn = sqlite3.connect(DB_SQLITE, timeout=5)
        cur = conn.cursor()
        cur.execute("SELECT username, max_connections, expires_at, status FROM ssh_users")
        for u, lim, exp_epoch, status in cur.fetchall():
            if u not in sys_managed:
                continue
            try:
                lim_val = max(1, int(lim))
            except Exception:
                lim_val = 1
            exp_val = int(exp_epoch) if exp_epoch else 0
            usuarios[u] = (lim_val, exp_val, status or "ACTIVO", sys_managed[u]["shell"], sys_managed[u]["uid"])
        conn.close()
    except Exception:
        pass
    return usuarios

def obtener_procesos_administrados(usuarios_autorizados):
    dropbear_pids, sshd_por_usuario = {}, {}
    uid_to_user = {info[4]: u for u, info in usuarios_autorizados.items()}
    allowed_names = set(usuarios_autorizados.keys())

    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/comm", "r") as f:
                comm = f.read().strip().lower()
            with open(f"/proc/{entry}/stat", "r") as f:
                stat_after = f.read().rsplit(")", 1)[-1].split()
            ppid, starttime = int(stat_after[1]), int(stat_after[19])
            if ppid <= 1:
                continue
            if "dropbear" in comm:
                dropbear_pids[entry] = starttime
            elif comm.startswith("sshd"):
                usr_detectado = None
                with open(f"/proc/{entry}/status", "r") as sf:
                    for sline in sf:
                        if sline.startswith("Uid:"):
                            real_uid = sline.split()[1]
                            if real_uid in uid_to_user:
                                usr_detectado = uid_to_user[real_uid]
                            break
                if not usr_detectado:
                    with open(f"/proc/{entry}/cmdline", "rb") as cf:
                        cmd = cf.read().replace(b"\x00", b" ").decode("latin1", errors="ignore")
                        m = re.search(r"sshd(?:-session)?:\s+([a-zA-Z0-9_-]+)(?:@|\[notty\]|$)", cmd)
                        if m and m.group(1) in allowed_names:
                            usr_detectado = m.group(1)
                if usr_detectado in allowed_names:
                    sshd_por_usuario.setdefault(usr_detectado, []).append((starttime, int(entry)))
        except Exception:
            continue
    return dropbear_pids, sshd_por_usuario

def actualizar_mapa_dropbear(dropbear_pids, allowed_names):
    global pid_memory
    activos = {(pid, st) for pid, st in dropbear_pids.items()}
    pid_memory = {k: v for k, v in pid_memory.items() if k in activos and v in allowed_names}
    faltantes = [pid for pid, st in dropbear_pids.items() if (pid, st) not in pid_memory]
    if faltantes:
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
            pid_m, usr_m = m.group(1), m.group(2)
            if pid_m in dropbear_pids and usr_m in allowed_names:
                pid_memory[(pid_m, dropbear_pids[pid_m])] = usr_m
        try:
            with open(CACHE_FILE + ".tmp", "w") as cf:
                for (pid, _), usr in pid_memory.items():
                    cf.write(f"{pid}:{usr}\n")
            os.replace(CACHE_FILE + ".tmp", CACHE_FILE)
        except Exception:
            pass
    db_por_usuario = {}
    for (pid, st), usr in pid_memory.items():
        if usr in allowed_names:
            db_por_usuario.setdefault(usr, []).append((st, int(pid)))
    return db_por_usuario

def bloquear_usuario_administrado(u, sesiones, motivo, nuevo_estado):
    for _, pid in sesiones:
        try:
            if pid > 1:
                os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
    subprocess.run(["usermod", "-L", "-s", "/bin/expired", "-e", "1970-01-02", u], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    subprocess.run(["passwd", "-l", u], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    registrar_evento_db(u, motivo, nuevo_estado)

def ciclo_control():
    usuarios = leer_usuarios_autorizados()
    if not usuarios:
        return
    dropbear_pids, sshd_por_usuario = obtener_procesos_administrados(usuarios)
    db_por_usuario = actualizar_mapa_dropbear(dropbear_pids, set(usuarios.keys()))
    ahora = int(time.time())
    for u, (lim, exp_epoch, est_manual, current_shell, _) in usuarios.items():
        sesiones = sshd_por_usuario.get(u, []) + db_por_usuario.get(u, [])
        bloqueado, motivo, nuevo_est = False, "", None
        if est_manual == "SUSPENDIDO":
            bloqueado, motivo, nuevo_est = True, "SUSPENSIÓN ADMINISTRATIVA", "SUSPENDIDO"
        elif est_manual == "BLOQUEADO_LIMITE":
            bloqueado, motivo, nuevo_est = True, "BLOQUEADO POR EXCESO DE LÍMITE", "BLOQUEADO_LIMITE"
        elif exp_epoch > 0 and ahora >= exp_epoch:
            bloqueado, motivo, nuevo_est = True, "CUENTA EXPIRADA POR TIEMPO", "VENCIDO"
        if bloqueado:
            if current_shell != "/bin/expired" or len(sesiones) > 0:
                bloquear_usuario_administrado(u, sesiones, motivo, nuevo_est)
            continue
        if len(sesiones) > lim:
            sesiones.sort(key=lambda x: x[0])
            excedentes = sesiones[lim:]
            for _, pid in excedentes:
                try:
                    if pid > 1:
                        os.kill(pid, signal.SIGKILL)
                except Exception:
                    pass
            registrar_evento_db(u, f"EXCESO DE LÍMITE CORREGIDO ({len(sesiones)}/{lim} sesiones)")

def main():
    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except IOError:
        return
    while True:
        try:
            ciclo_control()
        except Exception:
            pass
        time.sleep(3)

if __name__ == "__main__":
    main()
LIM_EOF

chmod 0755 /usr/local/bin/blue-limiter.py

cat << 'LSRV_EOF' > /etc/systemd/system/blue-limiter.service
[Unit]
Description=Demonio Auto-Limitador 24/7 Aislado (BLUE COMPANY v10.1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/blue-limiter.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
LSRV_EOF

systemctl daemon-reload
systemctl enable blue-limiter >/dev/null
systemctl restart blue-limiter

if ! systemctl is-active --quiet blue-limiter; then
    echo "ERROR: El servicio blue-limiter no pudo iniciar."
    exit 1
fi
echo "OK: Auto-Limitador 24/7 activo (Aislamiento exclusivo para cuentas BLUECOMPANY_MANAGED)"
