// =========================================================
//  Animaciones estilo Apple para las páginas públicas
//  (index.html, turno.html y cita.html). Se suma a movimiento.js.
//
//  - Portada: al bajar, la palabra gigante se aleja y el poste sube
//    más lento (paralaje), ligado al desplazamiento cuadro por cuadro.
//  - Tarjetas que se inclinan hacia el cursor con un resorte
//    (sin rebote, se puede interrumpir: parte de donde está).
//  - Al elegir servicio / día / hora / barbero: un «pop» suave.
//  - Textos y números que cambian se deslizan o cuentan.
//  Con «reducir movimiento» del teléfono no se mueve nada de esto.
// =========================================================
(() => {
  const reducido = matchMedia("(prefers-reduced-motion: reduce)");
  const fino = matchMedia("(hover: hover) and (pointer: fine)");
  if (!Element.prototype.animate) return;
  const css = getComputedStyle(document.documentElement);
  const RESORTE = css.getPropertyValue("--resorte").trim() || "cubic-bezier(.2,.9,.3,1)";
  const REBOTE = css.getPropertyValue("--resorte-rebote").trim() || "cubic-bezier(.2,1.25,.4,1)";

  // ---------- Resorte numérico (amortiguamiento 1.0, respuesta en segundos) ----------
  // Siempre continúa desde el valor y la velocidad actuales: cambiar el destino a medio camino no da saltos.
  function resorte(alCambiar, respuesta = 0.4) {
    const w = (2 * Math.PI) / respuesta;     // frecuencia natural
    let x = 0, v = 0, meta = 0, raf = 0, t0 = 0;
    const paso = (t) => {
      const dt = Math.min(0.032, (t - t0) / 1000 || 0.016); t0 = t;
      const a = -w * w * (x - meta) - 2 * w * v;   // críticamente amortiguado
      v += a * dt; x += v * dt;
      alCambiar(x);
      if (Math.abs(x - meta) > 0.001 || Math.abs(v) > 0.001) raf = requestAnimationFrame(paso);
      else { x = meta; v = 0; alCambiar(x); raf = 0; }
    };
    return (nueva) => { meta = nueva; if (!raf) { t0 = performance.now(); raf = requestAnimationFrame(paso); } };
  }

  // =========================================================
  //  Portada: palabra gigante y poste ligados al desplazamiento
  // =========================================================
  const hero = document.getElementById("hero");
  const gigante = hero?.querySelector(".gigante");
  const escena = document.getElementById("escena");
  if (hero && gigante) {
    let pedido = false;
    const pintar = () => {
      pedido = false;
      if (reducido.matches) { gigante.style.transform = ""; gigante.style.opacity = ""; return; }
      const alto = hero.offsetHeight || innerHeight;
      const k = Math.min(1, Math.max(0, scrollY / (alto * 0.85)));   // 0 arriba → 1 cuando el hero se fue
      // La palabra se aleja (más chica y más abierta) y se desvanece; nada de esto cambia el tamaño de la página
      gigante.style.transform = `translate3d(0, ${k * alto * 0.18}px, 0) scale(${1 - k * 0.12})`;
      gigante.style.opacity = String(1 - k * 0.9);
      if (escena) escena.style.translate = `0 ${-k * alto * 0.12}px`;
    };
    addEventListener("scroll", () => { if (!pedido) { pedido = true; requestAnimationFrame(pintar); } }, { passive: true });
    reducido.addEventListener?.("change", pintar);
    pintar();
  }

  // =========================================================
  //  Tarjetas que se inclinan hacia el cursor (solo con mouse)
  // =========================================================
  function inclinable(el, grados = 6) {
    if (el._incl) return; el._incl = true;
    let rx = 0, ry = 0, lev = 0;
    const poner = () => { el.style.transform = `perspective(700px) rotateX(${rx}deg) rotateY(${ry}deg) translateY(${-lev * 4}px)`; };
    const sx = resorte((x) => { rx = x; poner(); }, 0.4);
    const sy = resorte((y) => { ry = y; poner(); }, 0.4);
    const sl = resorte((l) => { lev = l; poner(); }, 0.35);
    el.addEventListener("pointermove", (e) => {
      if (!fino.matches || reducido.matches) return;
      const r = el.getBoundingClientRect();
      const px = (e.clientX - r.left) / r.width - 0.5, py = (e.clientY - r.top) / r.height - 0.5;
      sx(-py * grados); sy(px * grados); sl(1);
    });
    el.addEventListener("pointerleave", () => { sx(0); sy(0); sl(0); });
    el.addEventListener("pointerdown", () => sl(0.3));   // se hunde un poco al presionar, al instante
  }
  const prepararInclinables = (raiz = document) => raiz.querySelectorAll?.(".servicio, .paso").forEach((el) => inclinable(el));

  // =========================================================
  //  Al elegir algo: «pop» suave; la palomita llega con un pequeño rebote
  // =========================================================
  const ELEGIBLES = ".serv, .hora, .dia, .dm, .chip";
  function alElegir(el) {
    if (reducido.matches) return;
    el.animate([{ scale: 0.96 }, { scale: 1 }], { duration: 420, easing: RESORTE });
  }

  // =========================================================
  //  Textos que cambian: el nuevo entra deslizándose desde abajo
  // =========================================================
  function deslizarTexto(el) {
    if (reducido.matches || !el.isConnected) return;
    el.animate([{ opacity: 0, transform: "translateY(6px)" }, { opacity: 1, transform: "none" }], { duration: 380, easing: RESORTE });
  }

  // Números de «Mi turno» (número de turno, personas antes, minutos): cuentan hasta el valor nuevo.
  // La tarjeta se vuelve a dibujar cada vez, así que se comparan por su lugar, no por el elemento.
  const valores = new Map();
  let contando = 0;
  function revisarNumeros() {
    if (contando) return;
    document.querySelectorAll(".turno-num, .stat .v").forEach((el, i) => {
      const clave = (el.classList.contains("turno-num") ? "t" : "s") + i, ahora = el.textContent.trim(), antes = valores.get(clave);
      valores.set(clave, ahora);
      if (antes == null || antes === ahora || reducido.matches) return;
      const a = /-?\d+/.exec(antes), b = /-?\d+/.exec(ahora);
      if (!a || !b || a[0] === b[0]) return;
      const va = +a[0], vb = +b[0], ini = performance.now(), dur = 600;
      contando++;
      const paso = (t) => {
        if (!el.isConnected) { contando--; return; }
        const k = Math.min(1, (t - ini) / dur), x = 1 - (1 + 7.5 * k) * Math.exp(-7.5 * k);   // resorte sin rebote
        el.textContent = ahora.replace(b[0], String(Math.round(va + (vb - va) * (k >= 1 ? 1 : x))));
        if (k < 1) requestAnimationFrame(paso); else contando--;
      };
      requestAnimationFrame(paso);
    });
  }

  // La tarjeta del turno: cuando cambia de estado (te toca, terminó), aparece como material que llega
  function materializar(el) {
    if (reducido.matches) { el.animate([{ opacity: 0.4 }, { opacity: 1 }], { duration: 200 }); return; }
    el.animate([{ opacity: 0, transform: "scale(.97)", filter: "blur(6px)" }, { opacity: 1, transform: "none", filter: "blur(0)" }], { duration: 560, easing: RESORTE });
  }

  // =========================================================
  //  Observador: reacciona a lo que pintan las páginas
  // =========================================================
  let estadoTarjeta = null;
  const obs = new MutationObserver((ms) => {
    for (const m of ms) {
      const el = m.target.nodeType === 3 ? m.target.parentElement : m.target;
      if (!el) continue;
      if (m.type === "attributes") {
        if (m.attributeName === "aria-pressed" && el.matches(ELEGIBLES) && el.getAttribute("aria-pressed") === "true" && m.oldValue !== "true") alElegir(el);
        if (m.attributeName === "class" && el.id === "tarjetaTurno") {
          const tu = el.classList.contains("tu-turno");
          if (estadoTarjeta !== null && tu !== estadoTarjeta) materializar(el);
          estadoTarjeta = tu;
        }
        continue;
      }
      if (el.id === "resumen" || el.closest?.("#resumen")) { deslizarTexto(document.getElementById("resumen")); continue; }
      if (el.closest?.("#tarjetaTurno")) revisarNumeros();
      for (const n of m.addedNodes) if (n.nodeType === 1) prepararInclinables(n.parentElement || document);
    }
  });
  function iniciar() {
    prepararInclinables(); revisarNumeros();
    obs.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeOldValue: true, attributeFilter: ["aria-pressed", "class"] });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", iniciar); else iniciar();
})();
