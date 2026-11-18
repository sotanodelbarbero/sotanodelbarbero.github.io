// =========================================================
//  Movimiento estilo Apple (panel y páginas del cliente)
//  - Ventanas que entran y salen por el mismo camino, con resorte
//  - En el celular, las hojas se arrastran con el dedo para cerrarlas
//  - Controles segmentados con pastilla que se desliza
//  - Números que cuentan hasta su valor nuevo
//  - Pestañas que aparecen en cascada, avisos con rebote
//  Todo se puede interrumpir: siempre parte de donde está en pantalla.
// =========================================================
(() => {
  if (typeof Element === "undefined" || !Element.prototype.animate) return;   // navegador muy viejo: sin animaciones
  document.documentElement.classList.add("mov");
  const reducido = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
  const esHoja = () => matchMedia("(max-width: 620px)").matches;
  const css = getComputedStyle(document.documentElement);
  const RESORTE = css.getPropertyValue("--resorte").trim() || "cubic-bezier(.2,.9,.3,1)";
  const REBOTE = css.getPropertyValue("--resorte-rebote").trim() || "cubic-bezier(.2,1.25,.4,1)";
  const SALIDA = "cubic-bezier(.4,0,1,1)";
  // iOS Safari solo pinta :active si hay un escucha de toque
  document.addEventListener("touchstart", () => {}, { passive: true });

  // Valor en pantalla de la traslación vertical (para interrumpir sin saltos)
  const yActual = (el) => { const m = new DOMMatrixReadOnly(getComputedStyle(el).transform); return m.m42 || 0; };
  const pararAnim = (el) => el.getAnimations().forEach((a) => { if (a.id === "mov") { a.commitStyles?.(); a.cancel(); } });
  const anim = (el, frames, op) => { const a = el.animate(frames, { fill: "forwards", ...op }); a.id = "mov"; return a; };

  // =========================================================
  //  Ventanas (dialog): entrar, salir y arrastrar
  // =========================================================
  const P = HTMLDialogElement.prototype, abrirNativo = P.showModal, cerrarNativo = P.close;
  const backdrop = (d, a, b, dur, easing) => { try { d.animate([{ opacity: a }, { opacity: b }], { duration: dur, easing, pseudoElement: "::backdrop", fill: "forwards" }); } catch {} };

  function entrar(d) {
    pararAnim(d); d.style.transform = "";
    if (reducido()) { anim(d, [{ opacity: 0 }, { opacity: 1 }], { duration: 180, easing: "ease-out" }); return; }
    backdrop(d, 0, 1, 320, "ease-out");
    if (esHoja()) anim(d, [{ transform: "translateY(100%)" }, { transform: "translateY(0)" }], { duration: 520, easing: RESORTE });
    else anim(d, [{ opacity: 0, transform: "translateY(10px) scale(.96)" }, { opacity: 1, transform: "none" }], { duration: 420, easing: RESORTE });
  }
  // Salir por donde entró. Si viene de un arrastre, sigue a la velocidad del dedo.
  function salir(d, velocidad = 0) {
    return new Promise((listo) => {
      const desde = yActual(d);
      pararAnim(d);
      d.classList.add("saliendo");
      backdrop(d, 1, 0, 220, "ease-in");
      let a;
      if (reducido()) a = anim(d, [{ opacity: 1 }, { opacity: 0 }], { duration: 150, easing: "ease-in" });
      else if (esHoja()) {
        const alto = d.offsetHeight || innerHeight, falta = Math.max(0, alto - desde);
        const dur = velocidad > 300 ? Math.min(320, Math.max(140, falta / velocidad * 1000)) : 260;
        a = anim(d, [{ transform: `translateY(${desde}px)` }, { transform: "translateY(100%)" }], { duration: dur, easing: velocidad > 300 ? "linear" : SALIDA });
      } else a = anim(d, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateY(6px) scale(.97)" }], { duration: 180, easing: SALIDA });
      a.onfinish = listo; a.oncancel = listo;
    });
  }
  P.showModal = function () {
    if (this._saliendo) {   // la estaban cerrando y la vuelven a abrir: se regresa desde donde va
      this._saliendo = null; this.classList.remove("saliendo"); entrar(this);
      return;
    }
    abrirNativo.call(this);
    entrar(this);
  };
  P.close = function (valor) {
    if (!this.open || this._saliendo) return;
    const yo = this, token = {};
    this._saliendo = token;
    salir(this, this._velocidad || 0).then(() => {
      yo._velocidad = 0;
      if (yo._saliendo !== token) return;   // la volvieron a abrir a medio camino
      yo._saliendo = null;
      yo.classList.remove("saliendo"); pararAnim(yo); yo.style.transform = "";
      cerrarNativo.call(yo, valor);
    });
  };
  // Esc o el «atrás» del sistema también cierran con animación
  document.addEventListener("cancel", (e) => { if (e.target instanceof HTMLDialogElement) { e.preventDefault(); e.target.close(); } }, true);
  // Tocar fuera de la ventana (en el fondo oscuro) la cierra, como en iOS
  document.addEventListener("click", (e) => {
    const d = e.target;
    if (!(d instanceof HTMLDialogElement) || !d.open || d.dataset.fijo != null) return;
    if (d.querySelector("form, input, select, textarea")) return;   // con datos a medio llenar, no se cierra por accidente
    const r = d.getBoundingClientRect();
    if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) d.close();
  });

  // ---------- Arrastrar la hoja hacia abajo para cerrarla (celular) ----------
  const ligas = (sobra, dim, c = .55) => (sobra * dim * c) / (dim + c * Math.abs(sobra));   // resistencia en el borde
  const proyectar = (v, d = .99) => (v / 1000) * d / (1 - d);                               // a dónde llegaría con ese impulso
  let g = null;
  document.addEventListener("touchstart", (e) => {
    const d = e.target.closest?.("dialog[open]");
    if (!d || !esHoja() || d._saliendo || e.touches.length > 1) return;
    if (e.target.closest("input, select, textarea, [contenteditable], .no-arrastrar")) return;
    const t = e.touches[0];
    g = { d, y0: t.clientY, x0: t.clientX, arrastrando: false, scroll0: d.scrollTop, hist: [{ y: t.clientY, t: e.timeStamp }] };
  }, { passive: true });
  document.addEventListener("touchmove", (e) => {
    if (!g) return;
    const t = e.touches[0], dy = t.clientY - g.y0, dx = t.clientX - g.x0;
    if (!g.arrastrando) {
      if (g.d.scrollTop > 0 || g.scroll0 > 0) { g = null; return; }   // primero se desplaza el contenido
      if (Math.abs(dx) > Math.abs(dy) || dy < -6) { g = null; return; }
      if (dy < 8) return;                                              // umbral antes de decidir
      g.arrastrando = true; g.y0 = t.clientY; pararAnim(g.d);
    }
    e.preventDefault();
    const y = t.clientY - g.y0;
    g.d.style.transform = `translateY(${y >= 0 ? y : ligas(y, g.d.offsetHeight)}px)`;
    g.hist.push({ y: t.clientY, t: e.timeStamp }); if (g.hist.length > 6) g.hist.shift();
  }, { passive: false });
  const soltar = () => {
    if (!g) return;
    const { d, arrastrando, hist } = g; g = null;
    if (!arrastrando) return;
    const a = hist[0], b = hist.at(-1), v = b.t > a.t ? (b.y - a.y) / (b.t - a.t) * 1000 : 0;   // px/s
    const y = yActual(d), alto = d.offsetHeight;
    if (d.dataset.fijo == null && (y + proyectar(v) > alto * .45 || v > 1100)) { d._velocidad = Math.max(v, 0); d.close(); return; }
    // Regresa a su lugar con resorte, desde donde está
    const desde = y; d.style.transform = "";
    anim(d, [{ transform: `translateY(${desde}px)` }, { transform: "translateY(0)" }], { duration: 480, easing: v < -200 ? REBOTE : RESORTE });
  };
  document.addEventListener("touchend", soltar);
  document.addEventListener("touchcancel", soltar);

  // =========================================================
  //  Control segmentado: la pastilla se desliza al elegido
  // =========================================================
  function ponerPulgar(seg, animar = true) {
    const el = seg.querySelector(':scope > button[aria-pressed="true"]');
    let p = seg.querySelector(":scope > .seg-pulgar");
    if (!p) { p = document.createElement("span"); p.className = "seg-pulgar"; p.setAttribute("aria-hidden", "true"); seg.prepend(p); seg.classList.add("con-pulgar"); animar = false; }
    if (!el || !el.offsetWidth) { p.style.opacity = "0"; return; }
    p.classList.toggle("sin-anim", !animar || reducido());
    p.style.opacity = "1"; p.style.width = el.offsetWidth + "px"; p.style.transform = `translateX(${el.offsetLeft}px)`;
    if (!animar) requestAnimationFrame(() => p.classList.remove("sin-anim"));
  }
  const vistos = new WeakSet();
  const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver((es) => es.forEach((x) => ponerPulgar(x.target, false))) : null;
  function prepararSegs(raiz = document) {
    raiz.querySelectorAll?.(".seg").forEach((s) => { if (!vistos.has(s)) { vistos.add(s); ponerPulgar(s, false); ro?.observe(s); } });
  }

  // =========================================================
  //  Números que cuentan (tarjetas de cifras)
  // =========================================================
  const NUM = /^(\D*?)(-?[\d,]+(?:\.\d+)?)(\D*)$/;
  const yo = new WeakMap();   // texto que puso la animación (para no reaccionar a sí misma)
  function contar(el, antes, ahora) {
    const a = NUM.exec(antes.trim()), b = NUM.exec(ahora.trim());
    if (!a || !b || reducido() || !el.offsetParent) return;
    const va = Number(a[2].replace(/,/g, "")), vb = Number(b[2].replace(/,/g, ""));
    if (!isFinite(va) || !isFinite(vb) || va === vb) return;
    const dec = (b[2].split(".")[1] || "").length, fmt = new Intl.NumberFormat("es-MX", { minimumFractionDigits: dec, maximumFractionDigits: dec, useGrouping: true });
    const ini = performance.now(), dur = 650;
    cancelAnimationFrame(el._cuenta);
    const paso = (t) => {
      const k = Math.min(1, (t - ini) / dur), w = 7.5, x = 1 - (1 + w * k) * Math.exp(-w * k);   // resorte sin rebote
      const txt = b[1] + fmt.format(va + (vb - va) * (k >= 1 ? 1 : x)) + b[3];
      yo.set(el, txt); el.textContent = txt;
      if (k < 1) el._cuenta = requestAnimationFrame(paso); else yo.delete(el);
    };
    el._cuenta = requestAnimationFrame(paso);
  }
  const numerosObs = new MutationObserver((ms) => {
    for (const m of ms) {
      const el = m.target.nodeType === 3 ? m.target.parentElement : m.target;
      if (!el?.matches?.(".kpi .v, .pf-numeros .v")) continue;
      const ahora = el.textContent;
      if (yo.get(el) === ahora) continue;
      const antes = el._ultimo ?? ahora; el._ultimo = ahora;
      if (antes !== ahora) contar(el, yo.get(el) ?? antes, ahora);   // si iba contando, sigue desde lo que se ve
    }
  });
  // Guardar el último valor real para comparar
  const fijarUltimos = () => document.querySelectorAll(".kpi .v, .pf-numeros .v").forEach((el) => { if (el._ultimo == null) el._ultimo = el.textContent; });

  // =========================================================
  //  Pestañas del panel: el contenido aparece en cascada
  // =========================================================
  function cascada(sec) {
    if (reducido()) { anim(sec, [{ opacity: 0 }, { opacity: 1 }], { duration: 160 }); return; }
    [...sec.children].filter((c) => c.offsetParent !== null).slice(0, 8).forEach((c, i) =>
      anim(c, [{ opacity: 0, transform: "translateY(12px)" }, { opacity: 1, transform: "none" }], { duration: 520, delay: i * 40, easing: RESORTE, fill: "backwards" }));
  }

  // =========================================================
  //  Fila: el cliente que acaba de llegar brilla un momento
  // =========================================================
  let idsFila = null;
  function revisarFila(cola) {
    const ids = new Map([...cola.querySelectorAll(".visita")].map((v) => [v.querySelector("[data-id]")?.dataset.id, v]));
    if (idsFila) for (const [id, v] of ids) if (id && !idsFila.has(id)) {
      v.classList.add("llega");
      if (!reducido()) anim(v, [{ opacity: 0, transform: "translateY(-10px) scale(.98)" }, { opacity: 1, transform: "none" }], { duration: 560, easing: REBOTE, fill: "backwards" });
    }
    idsFila = new Set(ids.keys());
  }

  // =========================================================
  //  Avisos: bajan con rebote y se van hacia arriba
  // =========================================================
  function prepararToast(t) {
    if (t._mov) return; t._mov = true;
    if (!reducido()) anim(t, [{ opacity: 0, transform: "translate(-50%, -28px) scale(.9)" }, { opacity: 1, transform: "translate(-50%, 0) scale(1)" }], { duration: 560, easing: REBOTE });
    const quitar = Element.prototype.remove;
    t.remove = function () {
      if (this._fuera) return; this._fuera = true;
      if (reducido() || !this.isConnected) return quitar.call(this);
      const a = anim(this, [{ opacity: 1, transform: getComputedStyle(this).transform }, { opacity: 0, transform: "translate(-50%, -20px) scale(.94)" }], { duration: 200, easing: SALIDA });
      a.onfinish = () => quitar.call(this);
    };
  }

  // =========================================================
  //  Páginas del cliente: las tarjetas de abajo aparecen al llegar a ellas
  // =========================================================
  function revelar() {
    if (reducido() || !("IntersectionObserver" in window) || !document.body.classList.contains("pagina-cliente")) return;
    const io = new IntersectionObserver((es) => es.forEach((x) => { if (x.isIntersecting) { x.target.classList.add("mov-visto"); io.unobserve(x.target); } }), { rootMargin: "0px 0px -8% 0px" });
    document.querySelectorAll(".wrap > .card, .wrap > section, main > section").forEach((el) => {
      const r = el.getBoundingClientRect();
      if (r.top > innerHeight * .92) { el.classList.add("mov-revelar"); io.observe(el); }
    });
  }

  // =========================================================
  //  Arranque y observador general
  // =========================================================
  const obs = new MutationObserver((ms) => {
    for (const m of ms) {
      if (m.type === "attributes") {
        const el = m.target;
        if (m.attributeName === "aria-pressed" && el.parentElement?.classList.contains("seg")) ponerPulgar(el.parentElement, true);
        if (m.attributeName === "class" && el.tagName === "SECTION" && el.id?.startsWith("tab-") && !el.classList.contains("hidden") && (m.oldValue || "").includes("hidden")) cascada(el);
        if (m.attributeName === "aria-selected" && m.oldValue !== "true" && el.getAttribute("aria-selected") === "true" && el.closest(".tabs") && !reducido()) {
          const ico = el.querySelector("svg"); if (ico) anim(ico, [{ transform: "scale(.82)" }, { transform: "scale(1)" }], { duration: 520, easing: REBOTE });
        }
        continue;
      }
      for (const n of m.addedNodes) {
        if (n.nodeType !== 1) continue;
        if (n.classList.contains("toast")) prepararToast(n);
        if (n.classList.contains("seg") || n.querySelector?.(".seg")) prepararSegs(n.parentElement || document);
        if (n.matches?.(".kpi .v") || n.querySelector?.(".kpi .v")) fijarUltimos();
      }
      if (m.target.id === "cola") revisarFila(m.target);
    }
  });
  function iniciar() {
    prepararSegs(); fijarUltimos(); revelar();
    obs.observe(document.body, { subtree: true, childList: true, attributes: true, attributeOldValue: true, attributeFilter: ["aria-pressed", "class", "aria-selected"] });
    numerosObs.observe(document.body, { subtree: true, childList: true, characterData: true });
    addEventListener("resize", () => document.querySelectorAll(".seg.con-pulgar").forEach((s) => ponerPulgar(s, false)));
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", iniciar); else iniciar();
})();
