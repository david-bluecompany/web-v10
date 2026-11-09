import os
import re
import time
import hmac
import json
import secrets
import hashlib
import sqlite3
import platform
import subprocess
from datetime import datetime
from typing import Optional
import psutil
import httpx
from fastapi import FastAPI, Request, Response, HTTPException, Depends
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

VERSION_FILE = "/opt/blue-company/VERSION"
DB_PATH = "/etc/bluecompany/bluecompany.db"
SECRET_FILE = "/etc/bluecompany/secret.key"
PRIV_HELPER = "/usr/local/sbin/blue-priv-helper"
FRONTEND_DIR = "/opt/blue-company/frontend/dist"
GITHUB_RAW_BASE = "https://raw.githubusercontent.com/david-bluecompany/web-v10/main"

app = FastAPI(title="BLUE COMPANY WEB v10.1", docs_url=None, redoc_url=None)

def get_secret_key() -> bytes:
    if os.path.exists(SECRET_FILE):
        with open(SECRET_FILE, "rb") as f:
            return f.read().strip()
    key = secrets.token_hex(32).encode()
    os.makedirs(os.path.dirname(SECRET_FILE), exist_ok=True)
    with open(SECRET_FILE, "wb") as f:
        f.write(key)
    os.chmod(SECRET_FILE, 0o600)
    return key

SECRET_KEY = get_secret_key()

def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()

def hash_password(password: str, salt: Optional[str] = None) -> str:
    if not salt:
        salt = secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt.encode("utf-8"), 200000)
    return f"{salt}${dk.hex()}"

def verify_password(password: str, stored_hash: str) -> bool:
    try:
        salt, _ = stored_hash.split("$", 1)
        return hmac.compare_digest(hash_password(password, salt), stored_hash)
    except Exception:
        return False

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS admins (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            created_at INTEGER NOT NULL
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS ssh_users (
            username TEXT PRIMARY KEY,
            max_connections INTEGER NOT NULL DEFAULT 1,
            expires_at INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'ACTIVO',
            created_at INTEGER NOT NULL,
            notes TEXT DEFAULT ''
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS login_attempts (
            ip TEXT PRIMARY KEY,
            attempts INTEGER NOT NULL DEFAULT 0,
            locked_until INTEGER NOT NULL DEFAULT 0
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS audit_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            admin_user TEXT NOT NULL,
            ip TEXT NOT NULL,
            action TEXT NOT NULL,
            details TEXT NOT NULL
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS lock_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            username TEXT NOT NULL,
            reason TEXT NOT NULL
        )
    """)
    conn.commit()
    conn.close()

@app.on_event("startup")
def on_startup():
    init_db()

@app.get("/api/health")
def health_check():
    ver = open(VERSION_FILE).read().strip() if os.path.exists(VERSION_FILE) else "10.1.0"
    db_ok = os.path.exists(DB_PATH) and os.access(DB_PATH, os.R_OK | os.W_OK)
    if not db_ok:
        raise HTTPException(status_code=503, detail="Database not accessible")
    return {"status": "ok", "version": ver}

def run_priv(args: list[str], stdin_text: Optional[str] = None) -> str:
    cmd = ["sudo", "-n", PRIV_HELPER] + args
    proc = subprocess.run(
        cmd,
        input=stdin_text.encode("utf-8") if stdin_text else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60
    )
    out = proc.stdout.decode("utf-8", errors="ignore").strip()
    err = proc.stderr.decode("utf-8", errors="ignore").strip()
    if proc.returncode != 0 or out.startswith("ERROR:"):
        raise HTTPException(status_code=400, detail=out or err or "Error en operación privilegiada")
    return out

def log_audit(conn: sqlite3.Connection, admin: str, ip: str, action: str, details: str):
    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    conn.execute(
        "INSERT INTO audit_logs (timestamp, admin_user, ip, action, details) VALUES (?, ?, ?, ?, ?)",
        (now_str, admin, ip, action, details)
    )
    conn.commit()

def create_session_token(username: str, csrf_token: str) -> str:
    exp = int(time.time()) + 43200
    payload = f"{username}|{exp}|{csrf_token}"
    sig = hmac.new(SECRET_KEY, payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}|{sig}"

def require_auth(request: Request):
    token = request.cookies.get("bc_session")
    if not token:
        raise HTTPException(status_code=401, detail="No autenticado")
    parts = token.split("|")
    if len(parts) != 4:
        raise HTTPException(status_code=401, detail="Sesión inválida")
    username, exp_str, csrf_token, sig = parts
    payload = f"{username}|{exp_str}|{csrf_token}"
    expected_sig = hmac.new(SECRET_KEY, payload.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected_sig) or int(exp_str) < int(time.time()):
        raise HTTPException(status_code=401, detail="Sesión expirada")
    if request.method in ("POST", "PUT", "DELETE"):
        header_csrf = request.headers.get("X-CSRF-Token", "")
        if not hmac.compare_digest(header_csrf, csrf_token):
            raise HTTPException(status_code=403, detail="Token CSRF inválido")
    return {"username": username, "csrf_token": csrf_token}

class LoginInput(BaseModel):
    username: str = Field(..., min_length=3, max_length=32)
    password: str = Field(..., min_length=4, max_length=128)

class AdminPasswordInput(BaseModel):
    current_password: str
    new_password: str = Field(..., min_length=6, max_length=128)

class SSHUserCreate(BaseModel):
    username: Optional[str] = ""
    password: str = Field(default="1234", min_length=4, max_length=64)
    duration: str = Field(default="30d", pattern=r"^[0-9]+(m|h|d)$")
    max_connections: int = Field(default=1, ge=1, le=100)
    is_demo: bool = False
    notes: Optional[str] = ""

class SSHUserUpdate(BaseModel):
    password: Optional[str] = ""
    duration: Optional[str] = ""
    max_connections: Optional[int] = Field(default=None, ge=1, le=100)
    notes: Optional[str] = None

def parse_duration(dur: str) -> int:
    m = re.match(r"^([0-9]+)(m|h|d)$", dur.strip().lower())
    if not m:
        return 30 * 86400
    val, unit = int(m.group(1)), m.group(2)
    if unit == "m":
        return max(1, val) * 60
    if unit == "h":
        return max(1, val) * 3600
    return max(1, val) * 86400

@app.post("/api/auth/login")
def login(data: LoginInput, request: Request, response: Response, conn: sqlite3.Connection = Depends(get_db)):
    ip = request.client.host if request.client else "unknown"
    now = int(time.time())
    row = conn.execute("SELECT attempts, locked_until FROM login_attempts WHERE ip = ?", (ip,)).fetchone()
    if row and row["locked_until"] > now:
        wait_min = (row["locked_until"] - now + 59) // 60
        raise HTTPException(status_code=429, detail=f"Demasiados intentos fallidos. Bloqueado por {wait_min} min.")

    admin = conn.execute("SELECT username, password_hash FROM admins WHERE username = ?", (data.username,)).fetchone()
    if not admin or not verify_password(data.password, admin["password_hash"]):
        attempts = (row["attempts"] + 1) if row else 1
        locked_until = (now + 900) if attempts >= 5 else 0
        conn.execute(
            "INSERT INTO login_attempts (ip, attempts, locked_until) VALUES (?, ?, ?) "
            "ON CONFLICT(ip) DO UPDATE SET attempts = ?, locked_until = ?",
            (ip, attempts, locked_until, attempts, locked_until)
        )
        conn.commit()
        raise HTTPException(status_code=401, detail="Credenciales inválidas")

    conn.execute("DELETE FROM login_attempts WHERE ip = ?", (ip,))
    log_audit(conn, admin["username"], ip, "LOGIN_PANEL", "Inicio de sesión exitoso")
    csrf_token = secrets.token_hex(16)
    session_token = create_session_token(admin["username"], csrf_token)
    response.set_cookie(
        key="bc_session",
        value=session_token,
        httponly=True,
        secure=True,
        samesite="strict",
        max_age=43200
    )
    return {"username": admin["username"], "csrf_token": csrf_token}

@app.post("/api/auth/logout")
def logout(response: Response):
    response.delete_cookie("bc_session")
    return {"status": "ok"}

@app.get("/api/auth/me")
def auth_me(session: dict = Depends(require_auth)):
    return session

@app.post("/api/auth/password")
def change_admin_password(data: AdminPasswordInput, request: Request, session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    admin = conn.execute("SELECT password_hash FROM admins WHERE username = ?", (session["username"],)).fetchone()
    if not admin or not verify_password(data.current_password, admin["password_hash"]):
        raise HTTPException(status_code=400, detail="La contraseña actual no es correcta")
    new_hash = hash_password(data.new_password)
    conn.execute("UPDATE admins SET password_hash = ? WHERE username = ?", (new_hash, session["username"]))
    log_audit(conn, session["username"], request.client.host, "CAMBIO_CLAVE_ADMIN", "Contraseña de panel actualizada")
    return {"status": "ok"}

@app.get("/api/dashboard")
def get_dashboard(session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    vm = psutil.virtual_memory()
    sw = psutil.swap_memory()
    dk = psutil.disk_usage("/")
    net = psutil.net_io_counters()
    load1, load5, load15 = os.getloadavg()

    bbr = "Estándar"
    try:
        cc = subprocess.check_output(["sysctl", "-n", "net.ipv4.tcp_congestion_control"], stderr=subprocess.DEVNULL).decode().strip()
        if cc == "bbr":
            bbr = "BBR + LowLatency"
    except Exception:
        pass

    def check_srv(unit: str, proc_name: Optional[str] = None) -> bool:
        if subprocess.call(["systemctl", "is-active", "--quiet", unit]) == 0:
            return True
        if proc_name and subprocess.call(["pgrep", "-f", proc_name], stdout=subprocess.DEVNULL) == 0:
            return True
        return False

    managed_services = [
        {"id": "ssh", "name": "OpenSSH (P:22)", "active": check_srv("ssh", "sshd")},
        {"id": "dropbear", "name": "Dropbear SSH (P:2222)", "active": check_srv("dropbear", "dropbear")},
        {"id": "despachador", "name": "Despachador WS (P:80/8080/8880)", "active": check_srv("despachador", "despachador.py")},
        {"id": "badvpn", "name": "BadVPN UDPGW (P:7300)", "active": check_srv("badvpn", "badvpn-udpgw")},
        {"id": "blue-limiter", "name": "Auto-Limitador 24/7", "active": check_srv("blue-limiter", "blue-limiter.py")},
    ]

    external_services = [
        {"id": "xray", "name": "Xray Core", "active": check_srv("xray", "xray")},
        {"id": "x-ui", "name": "Panel 3X-UI", "active": check_srv("x-ui", "x-ui")},
        {"id": "v2ray", "name": "V2Ray Core", "active": check_srv("v2ray", "v2ray")},
        {"id": "nginx", "name": "Nginx Web Server", "active": check_srv("nginx", "nginx")},
        {"id": "hysteria-server", "name": "Hysteria 2 UDP", "active": check_srv("hysteria-server", "hysteria")},
        {"id": "fail2ban", "name": "Fail2ban IPS", "active": check_srv("fail2ban", "fail2ban")},
    ]

    now = int(time.time())
    users = conn.execute("SELECT username, expires_at, status FROM ssh_users").fetchall()
    total_users = len(users)
    expired_users = sum(1 for u in users if u["expires_at"] > 0 and u["expires_at"] <= now)
    suspended_users = sum(1 for u in users if u["status"] in ("SUSPENDIDO", "BLOQUEADO_LIMITE"))

    live_raw = run_priv(["live-telemetry"])
    live_data = json.loads(live_raw) if live_raw else {}
    online_users = sum(1 for v in live_data.values() if v.get("count", 0) > 0)
    active_tunnels = sum(v.get("count", 0) for v in live_data.values())

    ver = "10.1.0"
    if os.path.exists(VERSION_FILE):
        ver = open(VERSION_FILE).read().strip()

    return {
        "version": ver,
        "system": {
            "os": platform.platform(),
            "kernel": platform.release(),
            "arch": platform.machine(),
            "cores": psutil.cpu_count(logical=True),
            "uptime_seconds": int(time.time() - psutil.boot_time()),
            "tcp_engine": bbr,
            "load": f"{load1:.2f} | {load5:.2f} | {load15:.2f}"
        },
        "resources": {
            "cpu_percent": psutil.cpu_percent(interval=0.1),
            "ram_percent": vm.percent,
            "ram_used_gb": round(vm.used / (1024**3), 2),
            "ram_total_gb": round(vm.total / (1024**3), 2),
            "swap_percent": sw.percent,
            "disk_percent": dk.percent,
            "disk_free_gb": round(dk.free / (1024**3), 2),
            "disk_total_gb": round(dk.total / (1024**3), 2),
            "rx_gb": round(net.bytes_recv / (1024**3), 2),
            "tx_gb": round(net.bytes_sent / (1024**3), 2)
        },
        "counts": {
            "total_users": total_users,
            "online_users": online_users,
            "active_tunnels": active_tunnels,
            "expired_users": expired_users,
            "suspended_users": suspended_users
        },
        "managed_services": managed_services,
        "external_services": external_services
    }

@app.get("/api/users")
def list_users(session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    live_raw = run_priv(["live-telemetry"])
    live_map = json.loads(live_raw) if live_raw else {}
    now = int(time.time())
    rows = conn.execute("SELECT * FROM ssh_users ORDER BY created_at DESC").fetchall()
    result = []
    for r in rows:
        u = r["username"]
        exp = r["expires_at"]
        status = r["status"]
        if exp > 0 and now >= exp and status == "ACTIVO":
            status = "VENCIDO"
        tele = live_map.get(u, {"count": 0, "bytes": 0, "ip": "-", "etime": "-", "proto": "-"})
        result.append({
            "username": u,
            "max_connections": r["max_connections"],
            "active_connections": tele["count"],
            "client_ip": tele["ip"],
            "session_time": tele["etime"],
            "bytes_session": tele["bytes"],
            "expires_at": exp,
            "remaining_seconds": max(0, exp - now) if exp > 0 else 0,
            "status": status,
            "notes": r["notes"] or ""
        })
    return result

@app.post("/api/users")
def create_user(data: SSHUserCreate, request: Request, session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    username = (data.username or "").strip()
    if data.is_demo or not username:
        username = f"demo{secrets.randbelow(9000) + 1000}"
    if not re.match(r"^[a-zA-Z0-9_-]{1,32}$", username):
        raise HTTPException(status_code=400, detail="Usa solo letras, números, guiones (-) o (_) [máx 32 caract.]")
    if ":" in data.password:
        raise HTTPException(status_code=400, detail="La contraseña no puede contener ':'")

    now = int(time.time())
    dur_str = "30m" if data.is_demo and data.duration == "30d" else data.duration
    exp_epoch = now + parse_duration(dur_str)

    run_priv(["user-create", username, str(exp_epoch)], stdin_text=data.password + "\n")
    conn.execute(
        "INSERT INTO ssh_users (username, max_connections, expires_at, status, created_at, notes) VALUES (?, ?, ?, 'ACTIVO', ?, ?)",
        (username, data.max_connections, exp_epoch, now, data.notes or "")
    )
    log_audit(conn, session["username"], request.client.host, "CREAR_USUARIO", f"Usuario={username} Limite={data.max_connections} Dur={dur_str}")
    return {
        "username": username,
        "password": data.password,
        "max_connections": data.max_connections,
        "expires_at": exp_epoch,
        "duration": dur_str
    }

@app.put("/api/users/{username}")
def update_user(username: str, data: SSHUserUpdate, request: Request, session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    row = conn.execute("SELECT * FROM ssh_users WHERE username = ?", (username,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Usuario no encontrado en BLUE COMPANY")

    if data.password:
        if ":" in data.password:
            raise HTTPException(status_code=400, detail="Contraseña inválida")
        run_priv(["user-password", username], stdin_text=data.password + "\n")

    new_exp = row["expires_at"]
    if data.duration:
        new_exp = int(time.time()) + parse_duration(data.duration)
        run_priv(["user-expiry", username, str(new_exp)])
        if row["status"] == "VENCIDO":
            run_priv(["user-unlock", username, str(new_exp)])

    new_lim = data.max_connections if data.max_connections is not None else row["max_connections"]
    new_notes = data.notes if data.notes is not None else row["notes"]
    new_status = "ACTIVO" if (data.duration and row["status"] == "VENCIDO") else row["status"]

    conn.execute(
        "UPDATE ssh_users SET max_connections = ?, expires_at = ?, status = ?, notes = ? WHERE username = ?",
        (new_lim, new_exp, new_status, new_notes, username)
    )
    log_audit(conn, session["username"], request.client.host, "MODIFICAR_USUARIO", f"Usuario={username} Lim={new_lim}")
    return {"status": "ok"}

@app.post("/api/users/{username}/status")
def toggle_user_status(username: str, action: str, request: Request, session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    row = conn.execute("SELECT * FROM ssh_users WHERE username = ?", (username,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")

    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if action == "suspend":
        run_priv(["user-lock", username])
        conn.execute("UPDATE ssh_users SET status = 'SUSPENDIDO' WHERE username = ?", (username,))
        conn.execute("INSERT INTO lock_events (timestamp, username, reason) VALUES (?, ?, ?)", (now_str, username, "SUSPENSIÓN ADMINISTRATIVA WEB"))
        log_audit(conn, session["username"], request.client.host, "SUSPENDER_USUARIO", f"Usuario={username}")
    elif action == "activate":
        exp = row["expires_at"]
        if exp <= int(time.time()):
            exp = int(time.time()) + (30 * 86400)
        run_priv(["user-unlock", username, str(exp)])
        conn.execute("UPDATE ssh_users SET status = 'ACTIVO', expires_at = ? WHERE username = ?", (exp, username))
        log_audit(conn, session["username"], request.client.host, "REACTIVAR_USUARIO", f"Usuario={username}")
    elif action == "kick":
        run_priv(["user-kick", username])
        log_audit(conn, session["username"], request.client.host, "EXPULSAR_SESIONES", f"Usuario={username}")
    else:
        raise HTTPException(status_code=400, detail="Acción inválida")
    return {"status": "ok"}

@app.delete("/api/users/{username}")
def delete_user(username: str, request: Request, session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    row = conn.execute("SELECT username FROM ssh_users WHERE username = ?", (username,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    run_priv(["user-delete", username])
    conn.execute("DELETE FROM ssh_users WHERE username = ?", (username,))
    log_audit(conn, session["username"], request.client.host, "ELIMINAR_USUARIO", f"Usuario={username}")
    return {"status": "ok"}

@app.post("/api/users/purge-expired")
def purge_expired_users(request: Request, session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    now = int(time.time())
    expired = conn.execute("SELECT username FROM ssh_users WHERE expires_at > 0 AND expires_at <= ?", (now,)).fetchall()
    deleted = []
    for r in expired:
        u = r["username"]
        run_priv(["user-delete", u])
        conn.execute("DELETE FROM ssh_users WHERE username = ?", (u,))
        deleted.append(u)
    log_audit(conn, session["username"], request.client.host, "PURGAR_VENCIDOS", f"Eliminados={len(deleted)}")
    return {"deleted_count": len(deleted), "users": deleted}

@app.post("/api/services/{service_id}/{operation}")
def manage_service(service_id: str, operation: str, request: Request, session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    run_priv(["service-action", service_id, operation])
    log_audit(conn, session["username"], request.client.host, "CONTROL_SERVICIO", f"Servicio={service_id} Op={operation}")
    return {"status": "ok"}

@app.post("/api/modules/{module_name}")
def install_or_optimize_module(module_name: str, request: Request, session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    out = run_priv(["install-module", module_name])
    log_audit(conn, session["username"], request.client.host, "INSTALAR_MODULO", f"Modulo={module_name}")
    return {"status": "ok", "output": out}

@app.get("/api/network/ports")
def get_listening_ports(session: dict = Depends(require_auth)):
    out = run_priv(["ports-list"])
    ports = []
    for line in out.splitlines():
        parts = line.split("|")
        if len(parts) == 4:
            ports.append({"proto": parts[0], "port": parts[1], "process": parts[2], "owner": parts[3]})
    return ports

@app.get("/api/diagnostics")
def run_diagnostics(session: dict = Depends(require_auth)):
    out = run_priv(["diagnose"])
    return json.loads(out)

@app.post("/api/diagnostics/repair")
def repair_system(request: Request, session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    run_priv(["repair"])
    log_audit(conn, session["username"], request.client.host, "REPARACION_INTELIGENTE", "Reparación no disruptiva aplicada")
    return {"status": "ok"}

@app.get("/api/logs")
def get_logs(session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    audit = [dict(r) for r in conn.execute("SELECT * FROM audit_logs ORDER BY id DESC LIMIT 40").fetchall()]
    locks = [dict(r) for r in conn.execute("SELECT * FROM lock_events ORDER BY id DESC LIMIT 40").fetchall()]
    auth_raw = run_priv(["auth-logs"])
    return {"audit": audit, "locks": locks, "auth_log": auth_raw.splitlines()}

@app.get("/api/updater/check")
async def check_updates(session: dict = Depends(require_auth)):
    local_ver = open(VERSION_FILE).read().strip() if os.path.exists(VERSION_FILE) else "10.1.0"
    remote_ver = local_ver
    changelog = "Edición v10.1.0: Soporte Ubuntu 26.04 ARM64 / Python 3.14, reutilización SSL Let's Encrypt / 3X-UI y aislamiento estricto."
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.get(f"{GITHUB_RAW_BASE}/VERSION")
            if r.status_code == 200:
                remote_ver = r.text.strip()
    except Exception:
        pass
    return {
        "local_version": local_ver,
        "remote_version": remote_ver,
        "update_available": remote_ver != local_ver,
        "branch": "main",
        "changelog": changelog
    }

@app.post("/api/updater/apply")
def apply_update(request: Request, session: dict = Depends(require_auth), conn: sqlite3.Connection = Depends(get_db)):
    out = run_priv(["run-update"])
    log_audit(conn, session["username"], request.client.host, "ACTUALIZAR_GITHUB", out)
    return {"status": "ok", "output": out}

if os.path.exists(FRONTEND_DIR):
    app.mount("/assets", StaticFiles(directory=FRONTEND_DIR), name="assets")

    @app.get("/{full_path:path}")
    def serve_spa(full_path: str):
        return FileResponse(os.path.join(FRONTEND_DIR, "index.html"))
