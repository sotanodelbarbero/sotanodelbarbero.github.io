// =========================================================
//  Función "equipo": crear cuentas del personal y cambiar contraseñas.
//
//  Corre dentro de Supabase (Edge Function) porque necesita la llave de
//  administrador, que NUNCA debe ir en la página. Antes de hacer nada
//  revisa que quien la llama haya iniciado sesión y sea administrador.
//
//  Cómo instalarla (una sola vez):
//  Supabase → Edge Functions → Deploy a new function → Via Editor,
//  nombre: equipo, pega este archivo completo y dale Deploy.
// =========================================================
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const responder = (cuerpo, estado = 200) =>
  new Response(JSON.stringify(cuerpo), { status: estado, headers: { ...CORS, "Content-Type": "application/json" } });

const correoValido = (c) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(c);
const ROLES = ["barbero", "admin"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return responder({ error: "Método no permitido" }, 405);

  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // ¿Quién llama? Debe tener sesión y ser administrador.
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: sesion } = await sb.auth.getUser(jwt);
    const yo = sesion?.user;
    if (!yo) return responder({ error: "Tu sesión expiró. Vuelve a entrar al panel." }, 401);
    const { data: miPerfil } = await sb.from("perfiles").select("rol").eq("user_id", yo.id).maybeSingle();
    if (miPerfil?.rol !== "admin") return responder({ error: "Solo el administrador puede hacer esto." }, 403);

    const b = await req.json().catch(() => ({}));

    // ---------- Crear la cuenta de un barbero (o de otro admin) ----------
    if (b.accion === "crear") {
      const nombre = String(b.nombre || "").trim();
      const email = String(b.email || "").trim().toLowerCase();
      const password = String(b.password || "");
      const rol = ROLES.includes(b.rol) ? b.rol : "barbero";
      const comision = Number.isFinite(Number(b.comision_pct)) ? Math.min(100, Math.max(0, Number(b.comision_pct))) : 50;
      if (nombre.length < 2 || nombre.length > 80) return responder({ error: "Escribe el nombre (2 a 80 letras)." }, 400);
      if (!correoValido(email)) return responder({ error: "Escribe un correo válido." }, 400);
      if (password.length < 8) return responder({ error: "La contraseña debe tener al menos 8 caracteres." }, 400);

      // Barbero: el que ya existe (sin cuenta) o uno nuevo. Un admin que no corta no necesita barbero.
      let barberoId = b.barbero_id ? Number(b.barbero_id) : null;
      let barberoNuevo = false;
      if (barberoId) {
        const { data: ya } = await sb.from("perfiles").select("user_id").eq("barbero_id", barberoId).maybeSingle();
        if (ya) return responder({ error: "Ese barbero ya tiene una cuenta." }, 409);
      } else if (b.corta !== false) {
        const { data: nuevo, error: e1 } = await sb.from("barberos").insert({ nombre, comision_pct: comision }).select("id").single();
        if (e1) return responder({ error: "No se pudo crear el barbero: " + e1.message }, 500);
        barberoId = nuevo.id; barberoNuevo = true;
      }

      const { data: creado, error: e2 } = await sb.auth.admin.createUser({
        email, password, email_confirm: true, user_metadata: { nombre },
      });
      if (e2) {
        if (barberoNuevo) await sb.from("barberos").delete().eq("id", barberoId);   // deshacer
        const msg = /already|registered|exists/i.test(e2.message) ? "Ese correo ya tiene una cuenta." : e2.message;
        return responder({ error: msg }, 400);
      }

      // El perfil lo crea un trigger (03_roles.sql); aquí se aprueba y se liga al barbero.
      const { error: e3 } = await sb.from("perfiles").upsert(
        { user_id: creado.user.id, email, rol, barbero_id: barberoId }, { onConflict: "user_id" });
      if (e3) return responder({ error: "La cuenta se creó, pero no se pudo aprobar: " + e3.message }, 500);
      return responder({ ok: true, user_id: creado.user.id, barbero_id: barberoId });
    }

    // ---------- Cambiar la contraseña de alguien del equipo ----------
    if (b.accion === "password") {
      const password = String(b.password || "");
      if (!b.user_id) return responder({ error: "Falta la cuenta." }, 400);
      if (password.length < 8) return responder({ error: "La contraseña debe tener al menos 8 caracteres." }, 400);
      const { error } = await sb.auth.admin.updateUserById(b.user_id, { password });
      if (error) return responder({ error: error.message }, 400);
      return responder({ ok: true });
    }

    // ---------- Cambiar el correo con el que entra ----------
    if (b.accion === "correo") {
      const email = String(b.email || "").trim().toLowerCase();
      if (!b.user_id) return responder({ error: "Falta la cuenta." }, 400);
      if (!correoValido(email)) return responder({ error: "Escribe un correo válido." }, 400);
      const { error } = await sb.auth.admin.updateUserById(b.user_id, { email, email_confirm: true });
      if (error) return responder({ error: /already|registered|exists/i.test(error.message) ? "Ese correo ya lo usa otra cuenta." : error.message }, 400);
      await sb.from("perfiles").update({ email }).eq("user_id", b.user_id);
      return responder({ ok: true });
    }

    return responder({ error: "Acción desconocida." }, 400);
  } catch (e) {
    return responder({ error: "Error en el servidor: " + (e?.message || String(e)) }, 500);
  }
});
