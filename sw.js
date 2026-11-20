// Service worker del panel: recibe los avisos (notificaciones push) aunque el panel esté cerrado.
// No guarda nada en caché: el panel siempre se carga fresco de internet.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { title: "Barbería", body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "Barbería", {
    body: d.body || "",
    tag: d.tag || undefined,
    renotify: !!d.tag,
    icon: "icono-192.png",
    badge: "icono-192.png",
    vibrate: [120, 80, 120],
    data: { url: d.url || "panel.html" },
  }));
});

// Al tocar el aviso: abre el panel (o lo trae al frente si ya estaba abierto)
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = new URL(e.notification.data?.url || "panel.html", self.registration.scope).href;
  e.waitUntil((async () => {
    const abiertas = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const panel = abiertas.find((c) => new URL(c.url).pathname.endsWith("/panel.html"));
    if (panel) { await panel.focus(); try { await panel.navigate(url); } catch {} return; }
    await self.clients.openWindow(url);
  })());
});
