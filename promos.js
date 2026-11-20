// =========================================================
//  Promos para los clientes (index.html, cita.html, turno.html).
//  Muestra una franja con la próxima promo ACEPTADA por Alejandro
//  (las propuestas no se ven). Si no hay promos, no aparece nada.
// =========================================================
(async () => {
  const cfg = window.BARBERIA; if (!cfg?.supabaseUrl) return;
  let lista = [];
  try {
    const r = await fetch(cfg.supabaseUrl + "/rest/v1/rpc/promos_publicas", {
      method: "POST", body: "{}",
      headers: { apikey: cfg.supabaseKey, Authorization: "Bearer " + cfg.supabaseKey, "Content-Type": "application/json" },
    });
    if (!r.ok) return;
    lista = await r.json();
  } catch { return; }
  const hoy = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Mexico_City" }).format(new Date());
  const ahora = new Intl.DateTimeFormat("en-GB", { timeZone: "America/Mexico_City", hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date());
  // Quitar las de hoy que ya terminaron
  lista = (lista || []).filter((p) => p.fecha > hoy || (p.fecha === hoy && (!p.hora_fin || p.hora_fin > ahora)));
  if (!lista.length) return;
  const p = lista[0];
  const [y, m, d] = p.fecha.split("-").map(Number);
  const manana = new Date(Date.UTC(y, m - 1, d) - 864e5).toISOString().slice(0, 10) === hoy;
  const dia = p.fecha === hoy ? "Hoy" : manana ? "Mañana" : new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("es-MX", { timeZone: "UTC", weekday: "long", day: "numeric", month: "short" }).replace(/^./, (c) => c.toUpperCase());
  const desc = `${p.tipo === "porcentaje" ? Number(p.valor) + "%" : "$" + Number(p.valor)} de descuento ${p.texto}`;
  const horas = p.hora_ini ? ` de ${p.hora_ini} a ${p.hora_fin}` : "";
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  const css = document.createElement("style");
  css.textContent = `.promo-cinta { display: block; background: #fff; color: #0a0a0a; border-bottom: 1px solid rgba(10,10,10,.14); text-decoration: none; font: 500 .8125rem/1.35 "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, system-ui, sans-serif; }
    .promo-cinta div { max-width: 1240px; margin: 0 auto; padding: 10px clamp(16px, 4vw, 48px); display: flex; gap: 10px; align-items: center; justify-content: center; flex-wrap: wrap; text-align: center; }
    .promo-cinta .et { background: #0a0a0a; color: #fff; font-size: .625rem; font-weight: 600; letter-spacing: .18em; text-transform: uppercase; padding: 3px 8px; }
    .promo-cinta .ir { font-size: .6875rem; font-weight: 600; letter-spacing: .14em; text-transform: uppercase; border-bottom: 1.5px solid currentColor; white-space: nowrap; }
    .promo-cinta:hover .ir { opacity: .6; }`;
  document.head.appendChild(css);
  const a = document.createElement("a");
  a.className = "promo-cinta"; a.href = "cita.html";
  a.innerHTML = `<div><span class="et">Promo</span><span><b>${esc(dia)}:</b> ${esc(desc)}${esc(horas)}${lista.length > 1 ? ` · y ${lista.length - 1} más` : ""}</span><span class="ir">Agendar →</span></div>`;
  const tira = document.querySelector(".tira");
  if (tira) tira.after(a); else document.body.prepend(a);
})();
