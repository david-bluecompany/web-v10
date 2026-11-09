let csrfToken = "";
let cachedUsers = [];
let refreshTimer = null;

async function api(path, options = {}) {
  const headers = options.headers || {};
  if (csrfToken && ["POST", "PUT", "DELETE"].includes(options.method)) {
    headers["X-CSRF-Token"] = csrfToken;
  }
  if (options.body && typeof options.body === "object") {
    headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(options.body);
  }
  const res = await fetch(path, { ...options, headers });
  if (res.status === 401 && path !== "/api/auth/login") {
    showLogin();
    throw new Error("Sesión expirada");
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || "Error en la solicitud");
  return data;
}

function showLogin() {
  document.getElementById("login-view").classList.remove("hidden");
  document.getElementById("app-view").classList.add("hidden");
  if (refreshTimer) clearInterval(refreshTimer);
}

function showApp(username) {
  document.getElementById("login-view").classList.add("hidden");
  document.getElementById("app-view").classList.remove("hidden");
  document.getElementById("admin-chip").textContent = `👤 ${username}`;
  loadDashboard();
  loadUsers();
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = setInterval(() => {
    const activeTab = document.querySelector(".nav-btn.active")?.dataset.tab;
    if (activeTab === "tab-dashboard") loadDashboard();
    if (activeTab === "tab-live") loadUsers();
  }, 3000);
}

document.getElementById("login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const errEl = document.getElementById("login-error");
  errEl.classList.add("hidden");
  try {
    const username = document.getElementById("login-user").value.trim();
    const password = document.getElementById("login-pass").value;
    const res = await api("/api/auth/login", { method: "POST", body: { username, password } });
    csrfToken = res.csrf_token;
    showApp(res.username);
  } catch (err) {
    errEl.textContent = err.message;
    errEl.classList.remove("hidden");
  }
});

document.getElementById("logout-btn").addEventListener("click", async () => {
  await api("/api/auth/logout", { method: "POST" }).catch(() => {});
  showLogin();
});

document.getElementById("menu-toggle").addEventListener("click", () => {
  document.getElementById("sidebar").classList.toggle("open");
});

document.querySelectorAll(".nav-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
    document.querySelectorAll(".tab-panel").forEach((p) => p.classList.add("hidden"));
    btn.classList.add("active");
    const target = btn.dataset.tab;
    document.getElementById(target).classList.remove("hidden");
    document.getElementById("sidebar").classList.remove("open");
    if (target === "tab-dashboard") loadDashboard();
    if (target === "tab-users" || target === "tab-live") loadUsers();
    if (target === "tab-services") { loadDashboard(); loadPorts(); }
    if (target === "tab-diagnostics") loadDiagnostics();
    if (target === "tab-logs") loadLogs();
    if (target === "tab-updater") checkUpdates();
  });
});

async function loadDashboard() {
  try {
    const d = await api("/api/dashboard");
    document.getElementById("sidebar-version").textContent = `WEB v${d.version}`;
    document.getElementById("sys-os").textContent = `${d.system.os} (${d.system.arch})`;
    document.getElementById("sys-tcp").textContent = `TCP: ${d.system.tcp_engine}`;

    document.getElementById("stat-cpu").textContent = `${d.resources.cpu_percent}%`;
    document.getElementById("bar-cpu").style.width = `${d.resources.cpu_percent}%`;
    document.getElementById("stat-cores").textContent = `${d.system.cores} Núcleos | Carga: ${d.system.load}`;

    document.getElementById("stat-ram").textContent = `${d.resources.ram_percent}%`;
    document.getElementById("bar-ram").style.width = `${d.resources.ram_percent}%`;
    document.getElementById("stat-ram-detail").textContent = `${d.resources.ram_used_gb} GB / ${d.resources.ram_total_gb} GB (Swap: ${d.resources.swap_percent}%)`;

    document.getElementById("stat-disk").textContent = `${d.resources.disk_percent}%`;
    document.getElementById("bar-disk").style.width = `${d.resources.disk_percent}%`;
    document.getElementById("stat-disk-detail").textContent = `Libre: ${d.resources.disk_free_gb} GB de ${d.resources.disk_total_gb} GB`;

    const totalTraffic = (d.resources.rx_gb + d.resources.tx_gb).toFixed(2);
    document.getElementById("stat-traffic").textContent = `${totalTraffic} GB`;
    document.getElementById("stat-rxtx").textContent = `⬇ RX: ${d.resources.rx_gb} GB | ⬆ TX: ${d.resources.tx_gb} GB`;

    document.getElementById("kpi-total").textContent = d.counts.total_users;
    document.getElementById("kpi-online").textContent = d.counts.online_users;
    document.getElementById("kpi-tunnels").textContent = d.counts.active_tunnels;
    document.getElementById("kpi-expired").textContent = d.counts.expired_users + d.counts.suspended_users;

    const mBox = document.getElementById("dash-managed-services");
    const sCtrl = document.getElementById("services-control-list");
    mBox.innerHTML = "";
    sCtrl.innerHTML = "";
    d.managed_services.forEach((s) => {
      const badge = s.active ? `<span class="pill pill-success">● ACTIVO</span>` : `<span class="pill pill-danger">● DETENIDO</span>`;
      mBox.innerHTML += `<div class="service-item"><span>${s.name}</span>${badge}</div>`;
      sCtrl.innerHTML += `
        <div class="service-item">
          <div><strong>${s.name}</strong><br/>${badge}</div>
          <div class="btn-group">
            <button class="btn-secondary" onclick="serviceAction('${s.id}','restart')">Reiniciar</button>
            ${s.id !== "ssh" ? `<button class="btn-danger" onclick="serviceAction('${s.id}','${s.active ? "stop" : "start"}')">${s.active ? "Detener" : "Iniciar"}</button>` : ""}
          </div>
        </div>`;
    });

    const eBox = document.getElementById("dash-external-services");
    eBox.innerHTML = "";
    d.external_services.forEach((s) => {
      const badge = s.active ? `<span class="pill pill-success">● ACTIVO (Protegido)</span>` : `<span class="pill">○ No detectado</span>`;
      eBox.innerHTML += `<div class="service-item"><span>${s.name}</span>${badge}</div>`;
    });
  } catch (e) {}
}

function formatBytes(b) {
  if (!b || b <= 0) return "0 B";
  if (b < 1048576) return `${(b / 1024).toFixed(1)} KB`;
  if (b < 1073741824) return `${(b / 1048576).toFixed(2)} MB`;
  return `${(b / 1073741824).toFixed(2)} GB`;
}

function formatRemaining(sec) {
  if (sec <= 0) return "0m (Vencido)";
  if (sec < 3600) return `${Math.ceil(sec / 60)}m`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h ${Math.floor((sec % 3600) / 60)}m`;
  return `${Math.floor(sec / 86400)}d ${Math.floor((sec % 86400) / 3600)}h`;
}

async function loadUsers() {
  try {
    cachedUsers = await api("/api/users");
    renderUsers();
    renderLive();
  } catch (e) {}
}

function renderUsers() {
  const q = document.getElementById("user-search").value.toLowerCase();
  const filter = document.getElementById("user-filter").value;
  const tbody = document.getElementById("users-tbody");
  tbody.innerHTML = "";

  cachedUsers
    .filter((u) => {
      if (filter !== "ALL" && u.status !== filter) return false;
      return u.username.toLowerCase().includes(q) || (u.notes || "").toLowerCase().includes(q);
    })
    .forEach((u) => {
      const expDate = new Date(u.expires_at * 1000).toLocaleString();
      let pillClass = "pill-success";
      if (u.status === "VENCIDO") pillClass = "pill-danger";
      else if (u.status !== "ACTIVO") pillClass = "pill-warning";

      tbody.innerHTML += `
        <tr>
          <td><strong>${u.username}</strong></td>
          <td>${u.active_connections} / ${u.max_connections}</td>
          <td>${expDate}<br/><small class="text-muted">${formatRemaining(u.remaining_seconds)}</small></td>
          <td><span class="pill ${pillClass}">${u.status}</span></td>
          <td>${u.notes || "-"}</td>
          <td>
            <div class="btn-group">
              <button class="btn-secondary" onclick="openEditUser('${u.username}')">Editar</button>
              <button class="btn-secondary" onclick="showTicket('${u.username}', '***', ${u.max_connections}, '${expDate}')">Ticket</button>
              <button class="btn-secondary" onclick="userStatus('${u.username}', '${u.status === "ACTIVO" ? "suspend" : "activate"}')">
                ${u.status === "ACTIVO" ? "Suspender" : "Reactivar"}
              </button>
              <button class="btn-danger" onclick="deleteUser('${u.username}')">Borrar</button>
            </div>
          </td>
        </tr>`;
    });
}

function renderLive() {
  const tbody = document.getElementById("live-tbody");
  tbody.innerHTML = "";
  cachedUsers
    .filter((u) => u.active_connections > 0)
    .forEach((u) => {
      tbody.innerHTML += `
        <tr>
          <td><strong>${u.username}</strong></td>
          <td>${u.client_ip}</td>
          <td><span class="pill ${u.active_connections > u.max_connections ? "pill-danger" : "pill-success"}">${u.active_connections} / ${u.max_connections}</span></td>
          <td>${u.session_time}</td>
          <td>${formatBytes(u.bytes_session)}</td>
          <td>
            <button class="btn-secondary" onclick="userStatus('${u.username}', 'kick')">Expulsar (Kick)</button>
            <button class="btn-danger" onclick="userStatus('${u.username}', 'suspend')">Bloquear</button>
          </td>
        </tr>`;
    });
  if (!tbody.innerHTML) {
    tbody.innerHTML = `<tr><td colspan="6">No hay túneles activos en este momento.</td></tr>`;
  }
}

document.getElementById("user-search").addEventListener("input", renderUsers);
document.getElementById("user-filter").addEventListener("change", renderUsers);

document.getElementById("btn-new-user").addEventListener("click", () => {
  document.getElementById("modal-title").textContent = "Crear Nuevo Cliente SSH";
  document.getElementById("form-mode").value = "create";
  document.getElementById("form-username").disabled = false;
  document.getElementById("form-username").value = "";
  document.getElementById("form-password").value = "1234";
  document.getElementById("form-duration").value = "30d";
  document.getElementById("form-limit").value = "1";
  document.getElementById("form-notes").value = "";
  document.getElementById("user-modal").classList.remove("hidden");
});

document.getElementById("btn-new-demo").addEventListener("click", async () => {
  try {
    const res = await api("/api/users", { method: "POST", body: { is_demo: true, duration: "30m", max_connections: 1 } });
    await loadUsers();
    showTicket(res.username, res.password, res.max_connections, new Date(res.expires_at * 1000).toLocaleString());
  } catch (e) { alert(e.message); }
});

function openEditUser(username) {
  const u = cachedUsers.find((x) => x.username === username);
  if (!u) return;
  document.getElementById("modal-title").textContent = `Modificar Usuario: ${username}`;
  document.getElementById("form-mode").value = "edit";
  document.getElementById("form-username").value = username;
  document.getElementById("form-username").disabled = true;
  document.getElementById("form-password").value = "";
  document.getElementById("form-duration").value = "";
  document.getElementById("form-limit").value = u.max_connections;
  document.getElementById("form-notes").value = u.notes || "";
  document.getElementById("user-modal").classList.remove("hidden");
}

document.getElementById("user-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const mode = document.getElementById("form-mode").value;
  const username = document.getElementById("form-username").value.trim();
  const password = document.getElementById("form-password").value;
  const duration = document.getElementById("form-duration").value.trim();
  const max_connections = parseInt(document.getElementById("form-limit").value, 10);
  const notes = document.getElementById("form-notes").value;

  try {
    if (mode === "create") {
      const res = await api("/api/users", {
        method: "POST",
        body: { username, password: password || "1234", duration: duration || "30d", max_connections, notes }
      });
      closeModal("user-modal");
      await loadUsers();
      showTicket(res.username, res.password, res.max_connections, new Date(res.expires_at * 1000).toLocaleString());
    } else {
      await api(`/api/users/${username}`, {
        method: "PUT",
        body: { password, duration, max_connections, notes }
      });
      closeModal("user-modal");
      await loadUsers();
    }
  } catch (err) { alert(err.message); }
});

async function userStatus(username, action) {
  try {
    await api(`/api/users/${username}/status?action=${action}`, { method: "POST" });
    await loadUsers();
  } catch (e) { alert(e.message); }
}

async function deleteUser(username) {
  if (!confirm(`¿Confirmas eliminar definitivamente al cliente '${username}'?`)) return;
  try {
    await api(`/api/users/${username}`, { method: "DELETE" });
    await loadUsers();
  } catch (e) { alert(e.message); }
}

document.getElementById("btn-purge-expired").addEventListener("click", async () => {
  if (!confirm("¿Eliminar todas las cuentas vencidas administradas por BLUE COMPANY?")) return;
  try {
    const res = await api("/api/users/purge-expired", { method: "POST" });
    alert(`Se eliminaron ${res.deleted_count} cuentas vencidas.`);
    await loadUsers();
  } catch (e) { alert(e.message); }
});

function showTicket(u, pass, lim, exp) {
  const host = window.location.hostname;
  document.getElementById("ticket-text").textContent =
`╔══════════════════════════════════════════════════╗
║     CREDENCIALES DE ACCESO • BLUE COMPANY        ║
╠══════════════════════════════════════════════════╣
  Servidor / IP : ${host}
  Usuario       : ${u}
  Contraseña    : ${pass}
  Vencimiento   : ${exp}
  Dispositivos  : Máximo ${lim} simultáneos
────────────────────────────────────────────────────
  Puertos WS    : 80, 8080, 8880 (HTTP / WebSocket)
  Puerto Directo: 2222 (Dropbear) | 22 (OpenSSH)
  Puerto Juegos : 7300 (BadVPN UDPGW)
╚══════════════════════════════════════════════════╝`;
  document.getElementById("ticket-modal").classList.remove("hidden");
}

function copyTicket() {
  navigator.clipboard.writeText(document.getElementById("ticket-text").textContent);
  alert("Ticket copiado al portapapeles.");
}

function closeModal(id) {
  document.getElementById(id).classList.add("hidden");
}

async function serviceAction(srv, op) {
  try {
    await api(`/api/services/${srv}/${op}`, { method: "POST" });
    await loadDashboard();
  } catch (e) { alert(e.message); }
}

async function installModule(mod) {
  try {
    const res = await api(`/api/modules/${mod}`, { method: "POST" });
    alert(res.output || "Módulo configurado con éxito");
    await loadDashboard();
  } catch (e) { alert(e.message); }
}

async function loadPorts() {
  try {
    const ports = await api("/api/network/ports");
    const tbody = document.getElementById("ports-tbody");
    tbody.innerHTML = "";
    ports.forEach((p) => {
      tbody.innerHTML += `<tr><td>${p.proto}</td><td><strong>${p.port}</strong></td><td>${p.process}</td><td><span class="pill ${p.owner.includes("BLUE") ? "pill-success" : "pill-warning"}">${p.owner}</span></td></tr>`;
    });
  } catch (e) {}
}

async function loadDiagnostics() {
  const box = document.getElementById("diag-results");
  box.innerHTML = "Escaneando...";
  try {
    const res = await api("/api/diagnostics");
    if (res.healthy) {
      box.innerHTML = `<div class="service-item"><span class="pill pill-success">✓ SALUD ÓPTIMA</span><span>Todos los servicios, reglas NAT y /etc/shells operan sin fallos.</span></div>`;
    } else {
      box.innerHTML = res.issues.map((i) => `<div class="service-item"><span class="pill pill-danger">${i.code}</span><span>${i.msg}</span></div>`).join("");
    }
  } catch (e) { box.textContent = e.message; }
}

async function repairSystem() {
  try {
    await api("/api/diagnostics/repair", { method: "POST" });
    await loadDiagnostics();
    alert("Reparación aplicada sin interrumpir túneles activos.");
  } catch (e) { alert(e.message); }
}

async function loadLogs() {
  try {
    const res = await api("/api/logs");
    document.getElementById("audit-logs-box").innerHTML = res.audit.map((a) => `<div class="service-item"><small>${a.timestamp}</small><strong>${a.action}</strong><span>${a.details}</span></div>`).join("") || "Sin registros.";
    document.getElementById("lock-logs-box").innerHTML = res.locks.map((l) => `<div class="service-item"><small>${l.timestamp}</small><strong>${l.username}</strong><span>${l.reason}</span></div>`).join("") || "Sin bloqueos.";
    document.getElementById("auth-logs-pre").textContent = res.auth_log.join("\n") || "Sin eventos.";
  } catch (e) {}
}

async function checkUpdates() {
  try {
    const res = await api("/api/updater/check");
    document.getElementById("up-branch").textContent = res.branch;
    document.getElementById("up-local").textContent = res.local_version;
    document.getElementById("up-remote").textContent = res.remote_version;
    document.getElementById("up-changelog").textContent = res.changelog;
  } catch (e) {}
}

async function applyUpdate() {
  if (!confirm("¿Confirmas verificar integridad SHA256 y aplicar la actualización desde GitHub?")) return;
  try {
    const res = await api("/api/updater/apply", { method: "POST" });
    alert(res.output || "Actualización completada");
  } catch (e) { alert(e.message); }
}

document.getElementById("admin-pass-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  try {
    await api("/api/auth/password", {
      method: "POST",
      body: {
        current_password: document.getElementById("adm-curr-pass").value,
        new_password: document.getElementById("adm-new-pass").value
      }
    });
    alert("Contraseña actualizada correctamente.");
    e.target.reset();
  } catch (err) { alert(err.message); }
});

(async function init() {
  try {
    const me = await api("/api/auth/me");
    csrfToken = me.csrf_token;
    showApp(me.username);
  } catch (e) {
    showLogin();
  }
})();
