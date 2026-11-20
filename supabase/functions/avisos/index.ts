// =========================================================
//  Función "avisos": manda notificaciones al celular de los barberos.
//
//  La llama la base de datos cuando se agenda, cancela o mueve una cita
//  (ver supabase/15_notificaciones.sql), y el panel para «Activar avisos»
//  y «Probar».
//
//  Cómo instalarla (una sola vez, después de ejecutar 15_notificaciones.sql):
//  Supabase → Edge Functions → Deploy a new function → Via Editor,
//  nombre: avisos, pega este archivo completo y dale Deploy. DESPUÉS, en
//  la función → pestaña Details, apaga «Verify JWT with legacy secret»
//  (o «Enforce JWT verification») y guarda: la función revisa por su
//  cuenta quién la llama.
//
//  No hay que configurar llaves: la primera vez crea sus propias llaves de
//  notificación y las guarda en la base de datos (en el esquema privado).
// =========================================================
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const responder = (cuerpo, estado = 200) =>
  new Response(JSON.stringify(cuerpo), { status: estado, headers: { ...CORS, "Content-Type": "application/json" } });
const ZONA = "America/Mexico_City";
const PANEL = "https://sotanodelbarbero.github.io/panel.html";

// ---- WEBPUSH:INICIO ---- (Web Push estándar con WebCrypto: RFC 8291 y RFC 8292)
const te = new TextEncoder();
const b64u = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const desdeB64u = (s) => {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
};
const unir = (...partes) => {
  const out = new Uint8Array(partes.reduce((a, p) => a + p.length, 0));
  let i = 0; for (const p of partes) { out.set(p, i); i += p.length; }
  return out;
};
async function hmac(llave, datos) {
  const k = await crypto.subtle.importKey("raw", llave, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, datos));
}

// Llaves VAPID (las que identifican a la barbería ante Google, Apple y Mozilla)
async function crearVapid() {
  const par = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const jwk = await crypto.subtle.exportKey("jwk", par.privateKey);
  return JSON.stringify({ kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, d: jwk.d });
}
const vapidPublica = (jwk) => b64u(unir(new Uint8Array([4]), desdeB64u(jwk.x), desdeB64u(jwk.y)));

async function firmaVapid(jwk, endpoint, contacto) {
  const llave = await crypto.subtle.importKey("jwk", { ...jwk, ext: true }, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const cab = b64u(te.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const cuerpo = b64u(te.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: contacto })));
  const firma = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, llave, te.encode(cab + "." + cuerpo));
  return `vapid t=${cab}.${cuerpo}.${b64u(firma)}, k=${vapidPublica(jwk)}`;
}

// Cifra el mensaje para un celular (aes128gcm, RFC 8291). opciones.sal / opciones.efimera solo para pruebas.
async function cifrar(mensaje, p256dh, authSecreto, opciones = {}) {
  const uaPub = desdeB64u(p256dh), auth = desdeB64u(authSecreto);
  const efimera = opciones.efimera || await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const asPub = new Uint8Array(await crypto.subtle.exportKey("raw", efimera.publicKey));
  const uaLlave = await crypto.subtle.importKey("raw", uaPub, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const compartido = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaLlave }, efimera.privateKey, 256));
  const sal = opciones.sal || crypto.getRandomValues(new Uint8Array(16));

  const prkClave = await hmac(auth, compartido);
  const ikm = (await hmac(prkClave, unir(te.encode("WebPush: info\0"), uaPub, asPub, new Uint8Array([1])))).slice(0, 32);
  const prk = await hmac(sal, ikm);
  const cek = (await hmac(prk, unir(te.encode("Content-Encoding: aes128gcm\0"), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmac(prk, unir(te.encode("Content-Encoding: nonce\0"), new Uint8Array([1])))).slice(0, 12);

  const llaveAes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const texto = unir(typeof mensaje === "string" ? te.encode(mensaje) : mensaje, new Uint8Array([2]));
  const cifrado = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, llaveAes, texto));
  const rs = new Uint8Array([0, 0, 16, 0]);   // 4096
  return unir(sal, rs, new Uint8Array([asPub.length]), asPub, cifrado);
}

// Manda un aviso. Devuelve el código HTTP del servicio de notificaciones (201 = enviado; 404/410 = ya no existe)
async function enviarPush(sus, mensaje, jwk, contacto) {
  const cuerpo = await cifrar(JSON.stringify(mensaje), sus.p256dh, sus.auth);
  const r = await fetch(sus.endpoint, {
    method: "POST",
    headers: {
      Authorization: await firmaVapid(jwk, sus.endpoint, contacto),
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      TTL: "86400",
      Urgency: "high",
    },
    body: cuerpo,
  });
  await r.body?.cancel();
  return r.status;
}
// ---- WEBPUSH:FIN ----

const fechaBonita = (f, h) => {
  const d = new Date(`${f}T12:00:00Z`);
  const dia = d.toLocaleDateString("es-MX", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
  return `${dia} ${String(h || "").slice(0, 5)}`.trim();
};
const hoyLocal = () => new Intl.DateTimeFormat("en-CA", { timeZone: ZONA }).format(new Date());
const cuando = (f, h) => {
  const hoy = hoyLocal();
  const manana = new Date(Date.parse(hoy + "T12:00:00Z") + 864e5).toISOString().slice(0, 10);
  const hh = String(h || "").slice(0, 5);
  return f === hoy ? `hoy ${hh}` : f === manana ? `mañana ${hh}` : fechaBonita(f, h);
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return responder({ error: "Método no permitido" }, 405);

  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const cuerpo = await req.json().catch(() => ({}));

    // Llaves VAPID: se crean solas la primera vez
    const { data: guardada, error: eV } = await sb.rpc("ajuste_privado", { p_clave: "vapid_jwk" });
    if (eV) return responder({ error: "Falta ejecutar 15_notificaciones.sql en Supabase." }, 500);
    let jwkTexto = guardada;
    if (!jwkTexto) {
      const { data, error } = await sb.rpc("crear_ajuste_privado", { p_clave: "vapid_jwk", p_valor: await crearVapid() });
      if (error) return responder({ error: "No se pudieron crear las llaves: " + error.message }, 500);
      jwkTexto = data;
    }
    const jwk = JSON.parse(jwkTexto);
    const contacto = "https://sotanodelbarbero.github.io";

    // Manda a una lista de suscripciones y borra las que ya no existen
    async function mandar(subs, mensaje) {
      let enviados = 0, fallidos = 0;
      await Promise.all(subs.map(async (s) => {
        try {
          const st = await enviarPush(s, mensaje, jwk, contacto);
          if (st >= 200 && st < 300) enviados++;
          else {
            fallidos++;
            if (st === 404 || st === 410) await sb.from("push_suscripciones").delete().eq("id", s.id);
            else console.log("aviso rechazado", st, new URL(s.endpoint).host);
          }
        } catch (e) { fallidos++; console.log("aviso falló", String(e)); }
      }));
      return { enviados, fallidos };
    }

    // ---------- Llamada de la base de datos (una cita cambió) ----------
    const secreto = req.headers.get("x-avisos-secreto");
    if (secreto) {
      const { data: bueno } = await sb.rpc("ajuste_privado", { p_clave: "avisos_secreto" });
      if (!bueno || secreto !== bueno) return responder({ error: "No autorizado" }, 401);

      const { data: c } = await sb.from("citas").select("*").eq("id", Number(cuerpo.cita)).maybeSingle();
      if (!c) return responder({ ok: true, nada: "cita no encontrada" });
      const [{ data: perfiles }, { data: serv }, { data: barberos }] = await Promise.all([
        sb.from("perfiles").select("user_id,rol,barbero_id").not("rol", "is", null),
        sb.from("servicios").select("nombre").eq("id", c.servicio_id).maybeSingle(),
        sb.from("barberos").select("id,nombre"),
      ]);
      const nomBarbero = (id) => barberos?.find((b) => b.id === id)?.nombre || "cualquier barbero";
      // A quién: el barbero de la cita; si es «cualquiera», todo el equipo. Nunca a quien hizo el cambio.
      const usuariosDe = (barberoId) => (perfiles || [])
        .filter((p) => (barberoId == null || p.barbero_id === barberoId) && p.user_id !== cuerpo.actor)
        .map((p) => p.user_id);
      const detalle = `${c.cliente_nombre} · ${serv?.nombre || "Servicio"} (${c.duracion_min} min)`;
      const url = `${PANEL}#citas`;
      const envios = [];   // [usuarios, mensaje]

      if (cuerpo.tipo === "nueva") {
        envios.push([usuariosDe(c.barbero_id), {
          title: `Nueva cita · ${cuando(c.fecha, c.hora)}`,
          body: detalle + (c.barbero_id == null ? " · cualquier barbero" : ""), tag: `cita-${c.id}`, url }]);
      } else if (cuerpo.tipo === "cancelada") {
        envios.push([usuariosDe(c.barbero_id), {
          title: `Cita cancelada · ${cuando(c.fecha, c.hora)}`,
          body: detalle, tag: `cita-${c.id}`, url }]);
      } else if (cuerpo.tipo === "movida") {
        const a = cuerpo.antes || {};
        const antesBarbero = a.barbero_id ?? null;
        const cambioBarbero = antesBarbero !== (c.barbero_id ?? null);
        const antesTxt = cuando(a.fecha, a.hora);
        if (cambioBarbero) {
          envios.push([usuariosDe(c.barbero_id), {
            title: c.barbero_id == null ? `Cita para cualquier barbero · ${cuando(c.fecha, c.hora)}` : `Te pasaron una cita · ${cuando(c.fecha, c.hora)}`,
            body: detalle, tag: `cita-${c.id}`, url }]);
          if (antesBarbero != null) {
            const ya = new Set(envios[0][0]);
            envios.push([usuariosDe(antesBarbero).filter((u) => !ya.has(u)), {
              title: `Ya no es tuya: cita de ${antesTxt}`,
              body: `${c.cliente_nombre} pasó con ${nomBarbero(c.barbero_id)}`, tag: `cita-${c.id}`, url }]);
          }
        } else {
          envios.push([usuariosDe(c.barbero_id), {
            title: `Cita movida · ahora ${cuando(c.fecha, c.hora)}`,
            body: `${detalle} · antes ${antesTxt}`, tag: `cita-${c.id}`, url }]);
        }
      }

      let total = { enviados: 0, fallidos: 0 };
      for (const [usuarios, mensaje] of envios) {
        if (!usuarios.length) continue;
        const { data: subs } = await sb.from("push_suscripciones").select("*").in("user_id", usuarios);
        const r = await mandar(subs || [], mensaje);
        total.enviados += r.enviados; total.fallidos += r.fallidos;
      }
      return responder({ ok: true, ...total });
    }

    // ---------- Llamada del panel (alguien del equipo con sesión) ----------
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: sesion } = await sb.auth.getUser(token);
    const yo = sesion?.user;
    if (!yo) return responder({ error: "Tu sesión expiró. Vuelve a entrar al panel." }, 401);
    const { data: perfil } = await sb.from("perfiles").select("rol").eq("user_id", yo.id).maybeSingle();
    if (!perfil?.rol) return responder({ error: "Solo el personal puede activar avisos." }, 403);

    if (cuerpo.accion === "clave") return responder({ clave: vapidPublica(jwk) });

    if (cuerpo.accion === "prueba") {
      let q = sb.from("push_suscripciones").select("*").eq("user_id", yo.id);
      if (cuerpo.endpoint) q = q.eq("endpoint", cuerpo.endpoint);
      const { data: subs } = await q;
      if (!subs?.length) return responder({ error: "Este celular no tiene los avisos activados." }, 400);
      const r = await mandar(subs, { title: "¡Avisos activados! ✂️", body: "Así te llegará cada cita nueva, cancelada o movida.", tag: "prueba", url: PANEL });
      return responder(r);
    }
    return responder({ error: "Acción desconocida" }, 400);
  } catch (e) {
    return responder({ error: String(e?.message || e) }, 500);
  }
});
