#!/bin/bash
set -euo pipefail

cat << 'LIM_EOF' > /usr/local/bin/blue-limiter.py
#!/usr/bin/env python3
import os, re, time, fcntl, signal, sqlite3, subprocess
from datetime import datetime

DB_SQLITE = "/etc/bluecompany/bluecompany.db"
CACHE_FILE = "/run/blue-dropbear.map"
LOCK_FILE = "/run/blue-limiter-daemon.lock"
pid_memory = {}

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

def leer_base_usuarios():
    usuarios = {}
    if not os.path.exists(DB_SQLITE):
        return usuarios
    try:
        conn = sqlite3.connect(DB_SQLITE, timeout=5)
        cur = conn.cursor()
        cur.execute("SELECT username, max_connections, expires_at, status FROM ssh_users")
        for u, lim, exp_epoch, status in cur.fetchall():
            lim_val = max(1, int(lim)) if lim else 1
            exp_val = int(exp_epoch) if exp_epoch else 0
            usuarios[u] = (lim_val, exp_val, status or "ACTIVO")
        conn.close()
    except Exception:
        pass
    return usuarios

def obtener_procesos():
    dropbear_pids, sshd_por_usuario, uid_map = {}, {}, {}
    try:
        with open("/etc/passwd", "r", errors="ignore") as pf:
            for line in pf:
                p = line.strip().split(":")
                if len(p) >= 3:
                    uid_map[p[2]] = p[0]
    except Exception:
        pass
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/comm", "r") as f:
                comm = f.read().strip().lower()
            with open(f"/proc/{entry}/stat", "r") as f:
                stat_after = f.read().rsplit(")", 1)[-1].split()
            ppid, starttime = int(stat_after[1]), int(stat_after[19])
            if "dropbear" in comm and ppid > 1:
                dropbear_pids[entry] = starttime
            elif comm.startswith("sshd") and ppid > 1:
                usr_detectado = None
                with open(f"/proc/{entry}/status", "r") as sf:
                    for sline in sf:
                        if sline.startswith("Uid:"):
                            real_uid = sline.split()[1]
                            if real_uid != "0" and real_uid in uid_map:
                                usr_detectado = uid_map[real_uid]
                                break
                if not usr_detectado:
                    with open(f"/proc/{entry}/cmdline", "rb") as cf:
                        cmd = cf.read().replace(b"\x00", b" ").decode("latin1", errors="ignore")
                        m = re.search(r"sshd(?:-session)?:\s+([a-zA-Z0-9_-]+)(?:@|\[notty\]|$)", cmd)
                        if m and m.group(1) != "root":
                            usr_detectado = m.group(1)
                if usr_detectado:
                    sshd_por_usuario.setdefault(usr_detectado, []).append((starttime, int(entry)))
        except Exception:
            continue
    return dropbear_pids, sshd_por_usuario

def actualizar_mapa_dropbear(dropbear_pids, users):
    global pid_memory
    activos = {(pid, st) for pid, st in dropbear_pids.items()}
    pid_memory = {k: v for k, v in pid_memory.items() if k in activos}
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
            if m.group(1) in dropbear_pids:
                pid_memory[(m.group(1), dropbear_pids[m.group(1)])] = m.group(2)
        try:
            with open(CACHE_FILE + ".tmp", "w") as cf:
                for (pid, _), usr in pid_memory.items():
                    cf.write(f"{pid}:{usr}\n")
            os.replace(CACHE_FILE + ".tmp", CACHE_FILE)
        except Exception:
            pass
    db_por_usuario = {}
    for (pid, st), usr in pid_memory.items():
        db_por_usuario.setdefault(usr, []).append((st, int(pid)))
    return db_por_usuario

def bloquear_usuario_individual(u, sesiones, motivo, nuevo_estado):
    for _, pid in sesiones:
        try:
            if pid > 1:
                os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
    subprocess.run(["pkill", "-KILL", "-u", u], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    subprocess.run(["usermod", "-L", "-s", "/bin/expired", "-e", "1970-01-02", u], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    subprocess.run(["passwd", "-l", u], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    registrar_evento_db(u, motivo, nuevo_estado)

def ciclo_control():
    usuarios = leer_base_usuarios()
    if not usuarios:
        return
    dropbear_pids, sshd_por_usuario = obtener_procesos()
    db_por_usuario = actualizar_mapa_dropbear(dropbear_pids, list(usuarios.keys()))
    ahora = int(time.time())
    for u, (lim, exp_epoch, est_manual) in usuarios.items():
        if u == "root":
            continue
        sesiones = sshd_por_usuario.get(u, []) + db_por_usuario.get(u, [])
        bloqueado, motivo, nuevo_est = False, "", None
        if est_manual == "SUSPENDIDO":
            bloqueado, motivo, nuevo_est = True, "SUSPENSIÓN ADMINISTRATIVA", "SUSPENDIDO"
        elif est_manual == "BLOQUEADO_LIMITE":
            bloqueado, motivo, nuevo_est = True, "BLOQUEADO POR EXCESO DE LÍMITE", "BLOQUEADO_LIMITE"
        elif exp_epoch > 0 and ahora >= exp_epoch:
            bloqueado, motivo, nuevo_est = True, "CUENTA EXPIRADA POR TIEMPO", "VENCIDO"
        if bloqueado:
            ya_expirado = False
            try:
                with open("/etc/passwd", "r") as pf:
                    for line in pf:
                        if line.startswith(f"{u}:") and "/bin/expired" in line:
                            ya_expirado = True
                            break
            except Exception:
                pass
            if not ya_expirado:
                bloquear_usuario_individual(u, sesiones, motivo, nuevo_est)
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

chmod 755 /usr/local/bin/blue-limiter.py

cat << 'LSRV_EOF' > /etc/systemd/system/blue-limiter.service
[Unit]
Description=Demonio Auto-Limitador 24/7 SQLite (BLUE COMPANY v10.0)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/blue-limiter.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
LSRV_EOF

systemctl daemon-reload
systemctl enable blue-limiter &>/dev/null
systemctl restart blue-limiter &>/dev/null
echo "OK: Auto-Limitador 24/7 activado"
