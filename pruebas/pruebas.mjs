// Pruebas de casos de uso de la base de datos de la barbería con PGlite (Postgres en WASM).
// Uso: cd pruebas && npm install && npm test   (no toca tu Supabase: corre en una base de datos temporal)
import { PGlite } from "@electric-sql/pglite";
import fs from "node:fs";
import path from "node:path";

const dir = process.argv[2];
const db = new PGlite();
let ok = 0, mal = 0;
const fallas = [];

async function q(sql, params) { return (await db.query(sql, params)).rows; }
async function uno(sql, params) { const r = await q(sql, params); return r[0] ? Object.values(r[0])[0] : undefined; }
function prueba(nombre, cond, detalle = "") {
  if (cond) { ok++; console.log("  ✔ " + nombre); }
  else { mal++; fallas.push(nombre); console.log("  ✘ " + nombre + (detalle ? "  →  " + detalle : "")); }
}
async function error(sql, params) { try { await q(sql, params); return null; } catch (e) { return e.message; } }
const reloj = (ts) => db.exec(`select set_config('test.ahora', '${ts}', false)`);
const como = async (uid) => db.exec(`select set_config('test.uid', '${uid || ""}', false)`);
const seccion = (t) => console.log("\n" + t);

// ---------- Lo que Supabase trae de fábrica ----------
await db.exec(`
  create schema auth;
  create table auth.users (id uuid primary key default gen_random_uuid(), email text);
  create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
  create role anon nologin; create role authenticated nologin;
  grant usage on schema public, auth to anon, authenticated;
  alter default privileges in schema public grant all on tables to anon, authenticated;
  alter default privileges in schema public grant all on sequences to anon, authenticated;
  create publication supabase_realtime;
`);

// ---------- Cargar los archivos del proyecto en orden ----------
for (const f of ["schema.sql", "03_roles.sql", "04_admin.sql", "05_cliente.sql", "06_productos.sql", "07_citas.sql", "08_panel.sql", "09_calendario.sql", "10_equipo.sql", "11_llegada.sql"]) {
  try { await db.exec(fs.readFileSync(path.join(dir, f), "utf8")); console.log("cargado " + f); }
  catch (e) { console.log("ERROR al cargar " + f + ": " + e.message); process.exit(1); }
}
// 07 y 08 se ejecutan dos veces: deben poder repetirse sin error
for (const f of ["07_citas.sql", "08_panel.sql", "09_calendario.sql", "10_equipo.sql", "11_llegada.sql"]) {
  try { await db.exec(fs.readFileSync(path.join(dir, f), "utf8")); prueba(f + " se puede volver a ejecutar", true); }
  catch (e) { prueba(f + " se puede volver a ejecutar", false, e.message); }
}

// Reloj de pruebas: reemplaza la hora real por test.ahora
await db.exec(`
  create or replace function public.ahora_local() returns timestamp language sql stable as $$ select current_setting('test.ahora')::timestamp $$;
  create or replace function public.hoy_local() returns date language sql stable as $$ select public.ahora_local()::date $$;
`);

// ---------- Datos: 2 barberos, servicios, personal ----------
await db.exec(`
  insert into barberos (nombre) values ('Juan'), ('Pedro');
  update servicios set duracion_min = 60 where nombre = 'Corte + barba';
  insert into auth.users (id, email) values
    ('00000000-0000-0000-0000-00000000000a', 'alejandro@x.com'),
    ('00000000-0000-0000-0000-00000000000b', 'juan@x.com'),
    ('00000000-0000-0000-0000-00000000000c', 'nuevo@x.com');
  update perfiles set rol = 'admin' where email = 'alejandro@x.com';
  update perfiles set rol = 'barbero', barbero_id = 1 where email = 'juan@x.com';
`);
const CORTE = await uno(`select id from servicios where nombre = 'Corte'`);
const CB = await uno(`select id from servicios where nombre = 'Corte + barba'`);
const ADMIN = "00000000-0000-0000-0000-00000000000a", BARB = "00000000-0000-0000-0000-00000000000b", PEND = "00000000-0000-0000-0000-00000000000c";
// martes 17 nov 2026; miércoles 18; domingo 22
const turno = (n, t, s = CORTE) => uno(`select registrar_turno($1, $2, $3)`, [n, t, s]);
const agendar = (n, t, s, b, f, h) => uno(`select agendar_cita($1,$2,$3,$4,$5,$6)`, [n, t, s, b, f, h]);
const libres = async (f, s, b = null) => (await uno(`select horarios_disponibles($1,$2,$3)`, [f, s, b])) || [];

// =========================================================
seccion("TURNOS SIN CITA (fila del día)");
await reloj("2026-11-17 11:00");
let c = await uno(`select cola_publica()`);
prueba("A las 11:00 de un martes está abierto y acepta turnos", c.abierto === true && c.acepta === true, JSON.stringify(c));
prueba("Sin nadie en la fila la espera es 0", c.esperando === 0 && c.minutos === 0, JSON.stringify(c));

let t1 = await turno("Ana López", "55 1111 1111");
prueba("Ana toma turno → turno 1", t1.turno === 1, JSON.stringify(t1));
let t1b = await turno("Ana López", "5511111111");
prueba("Ana vuelve a tocar el botón → recibe el MISMO turno, no uno nuevo", t1b.turno === 1 && t1b.repetido === true, JSON.stringify(t1b));
let t2 = await turno("Beto", null, CB);
prueba("Beto (sin teléfono) toma turno → turno 2", t2.turno === 2);
let t3 = await turno("Carla", "5533333333");
let e3 = await uno(`select estado_turno($1)`, [t3.token]);
prueba("Carla ve 2 personas antes que ella", e3.antes === 2, JSON.stringify(e3));
prueba("Espera de Carla = (30 + 60) / 2 barberos = 45 min", e3.minutos === 45, "minutos=" + e3.minutos);
prueba("Nombre en el turno solo muestra el primer nombre", (await uno(`select estado_turno($1)`, [t1.token])).nombre === "Ana");

await reloj("2026-11-17 08:00");
prueba("A las 8:00 (antes de abrir) no deja tomar turno", (await error(`select registrar_turno('Dan','5544444444',${CORTE})`))?.includes("Cerrado"));
c = await uno(`select cola_publica()`);
prueba("A las 8:00 dice que abre hoy a las 10:00", c.abierto === false && c.proxima_fecha === "2026-11-17" && c.proxima_hora === "10:00", JSON.stringify(c));

await reloj("2026-11-22 12:00"); // domingo cerrado
c = await uno(`select cola_publica()`);
prueba("Domingo: cerrado, próxima apertura lunes 23 a las 10:00", c.abierto === false && c.proxima_fecha === "2026-11-23" && c.proxima_hora === "10:00", JSON.stringify(c));
prueba("Domingo: no deja tomar turno", (await error(`select registrar_turno('Dan','5544444444',${CORTE})`))?.includes("Cerrado"));

await reloj("2026-11-17 19:20");
c = await uno(`select cola_publica()`);
prueba("A las 19:20 con 3 en fila ya no acepta turnos (no alcanza antes de las 20:00)", c.abierto === true && c.acepta === false, JSON.stringify(c));
prueba("A las 19:20 registrar_turno lo rechaza con mensaje claro", (await error(`select registrar_turno('Dan','5544444444',${CORTE})`))?.includes("no alcanza"));
await reloj("2026-11-17 20:00");
prueba("A las 20:00 en punto ya está cerrado", (await uno(`select cola_publica()`)).abierto === false);

await reloj("2026-11-17 11:05");
await como(null);
prueba("El personal sí puede agregar clientes a mano fuera de las reglas (registrar_visita)", (await uno(`select registrar_visita('Mostrador', null, ${CORTE})`)) === 4);

// =========================================================
seccion("CITAS: horarios disponibles");
await reloj("2026-11-17 11:00");
let L = await libres("2026-11-18", CORTE);
prueba("Miércoles, corte de 30 min: 20 horarios de 10:00 a 19:30", L.length === 20 && L[0] === "10:00" && L.at(-1) === "19:30", L.join(" "));
L = await libres("2026-11-18", CB);
prueba("Corte + barba (60 min): el último horario es 19:00 (termina a las 20:00)", L.at(-1) === "19:00", L.at(-1));
L = await libres("2026-11-17", CORTE);
prueba("Hoy a las 11:00: el primero es 11:30 (mínimo 15 min de anticipación)", L[0] === "11:30", L[0]);
prueba("Domingo: no hay horarios", (await libres("2026-11-22", CORTE)).length === 0);
prueba("Ayer: no hay horarios", (await libres("2026-11-16", CORTE)).length === 0);
prueba("Más de 30 días adelante: no hay horarios", (await libres("2026-12-20", CORTE)).length === 0);

seccion("CITAS: agendar y cupo por barbero");
let a1 = await agendar("Diego Ruiz", "55 5555 5555", CORTE, 1, "2026-11-18", "17:00");
prueba("Diego agenda con Juan el miércoles 17:00", a1?.hora === "17:00" && !!a1.token, JSON.stringify(a1));
prueba("Juan ya no aparece libre a las 17:00", !(await libres("2026-11-18", CORTE, 1)).includes("17:00"));
prueba("Con 'Cualquiera' las 17:00 siguen libres (Pedro está libre)", (await libres("2026-11-18", CORTE)).includes("17:00"));
prueba("Pedro sí está libre a las 17:00", (await libres("2026-11-18", CORTE, 2)).includes("17:00"));
prueba("Otro cliente no puede apartar a Juan a las 17:00",
  (await error(`select agendar_cita('Eva','5566666666',${CORTE},1,'2026-11-18','17:00')`))?.includes("no está disponible"));
let a2 = await agendar("Eva", "5566666666", CORTE, null, "2026-11-18", "17:00");
prueba("Eva agenda con 'Cualquiera' a las 17:00", !!a2?.token);
prueba("Ya con 2 citas (2 barberos) las 17:00 se llenan para todos", !(await libres("2026-11-18", CORTE)).includes("17:00") && !(await libres("2026-11-18", CORTE, 2)).includes("17:00"));
prueba("Un tercero no puede apartar las 17:00",
  (await error(`select agendar_cita('Fer','5577777777',${CORTE},null,'2026-11-18','17:00')`))?.includes("no está disponible"));
L = await libres("2026-11-18", CB);
prueba("Corte + barba (60 min) no cabe a las 16:30 (se enciman las 17:00)", !L.includes("16:30") && L.includes("16:00"), L.join(" "));
prueba("Las 17:30 siguen libres (las citas de 17:00 terminan 17:30)", (await libres("2026-11-18", CORTE)).includes("17:30"));

seccion("CITAS: reglas de abuso y datos inválidos");
prueba("Diego no puede apartar otra cita el mismo día",
  (await error(`select agendar_cita('Diego','5555555555',${CORTE},null,'2026-11-18','12:00')`))?.includes("ese día"));
await agendar("Diego", "5555555555", CORTE, null, "2026-11-19", "12:00");
prueba("Diego no puede tener más de 2 citas a futuro",
  (await error(`select agendar_cita('Diego','5555555555',${CORTE},null,'2026-11-20','12:00')`))?.includes("2 citas"));
prueba("Hora que no es múltiplo de 30 (17:15) se rechaza",
  (await error(`select agendar_cita('Gil','5588888888',${CORTE},null,'2026-11-18','12:15')`))?.includes("Hora inválida"));
prueba("Teléfono de menos de 10 dígitos se rechaza",
  (await error(`select agendar_cita('Gil','55123',${CORTE},null,'2026-11-18','12:00')`))?.includes("Teléfono"));
prueba("Nombre de 1 letra se rechaza",
  (await error(`select agendar_cita('G','5588888888',${CORTE},null,'2026-11-18','12:00')`))?.includes("Nombre"));
prueba("Fuera de horario (21:00) se rechaza",
  (await error(`select agendar_cita('Gil','5588888888',${CORTE},null,'2026-11-18','21:00')`))?.includes("no está disponible"));
prueba("En domingo se rechaza",
  (await error(`select agendar_cita('Gil','5588888888',${CORTE},null,'2026-11-22','12:00')`))?.includes("no está disponible"));
prueba("En el pasado se rechaza",
  (await error(`select agendar_cita('Gil','5588888888',${CORTE},null,'2026-11-17','10:30')`))?.includes("no está disponible"));

seccion("CITAS: cliente consulta y cancela");
let ec = await uno(`select estado_cita($1)`, [a1.token]);
prueba("Diego ve su cita: Juan, 17:00, agendada, cancelable", ec.barbero === "Juan" && ec.hora === "17:00" && ec.estado === "agendada" && ec.cancelable === true, JSON.stringify(ec));
prueba("Eva (Cualquiera) ve barbero vacío", (await uno(`select estado_cita($1)`, [a2.token])).barbero === null);
prueba("Eva cancela su cita", (await uno(`select cancelar_cita($1)`, [a2.token])) === true);
prueba("Al cancelar, las 17:00 se liberan para 'Cualquiera'", (await libres("2026-11-18", CORTE)).includes("17:00"));
prueba("Cancelar dos veces no hace nada", (await uno(`select cancelar_cita($1)`, [a2.token])) === false);
prueba("Un token inventado no muestra nada", (await uno(`select estado_cita('00000000-0000-0000-0000-000000000000')`)) === null);

seccion("DÍA DE LA CITA: llegada y prioridad en la fila");
await reloj("2026-11-18 16:30");
let w1 = await turno("Hugo", "5512121212");           // llega sin cita
let w2 = await turno("Iván", "5513131313", CB);
let antesDeCitas = await uno(`select estado_turno($1)`, [w2.token]);
prueba("La espera de quien llega sin cita incluye la cita de las 17:00 que está por llegar",
  antesDeCitas.minutos >= Math.ceil((30 + 30) / 2), JSON.stringify(antesDeCitas));
const citaId = await uno(`select id from citas where token = $1`, [a1.token]);
await como(null);
prueba("Sin sesión no se puede marcar 'Llegó'", (await error(`select llegada_cita(${citaId})`))?.includes("Sin permiso"));
await como(PEND);
prueba("Una cuenta pendiente (sin rol) no puede marcar 'Llegó'", (await error(`select llegada_cita(${citaId})`))?.includes("Sin permiso"));
await como(BARB);
await reloj("2026-11-18 16:55");
let tc = await uno(`select llegada_cita(${citaId})`);
prueba("El barbero marca 'Llegó' → Diego entra a la fila", typeof tc === "number", String(tc));
const vis = (await q(`select * from visitas where fecha = '2026-11-18' and turno = $1`, [tc]))[0];
prueba("La visita queda con Juan asignado y la hora de su cita", vis.barbero_id == 1 && String(vis.hora_cita).startsWith("17:00"), JSON.stringify(vis));
prueba("La cita queda como 'llego' y ligada a la visita", (await uno(`select estado from citas where id = ${citaId}`)) === "llego");
const eDiego = await uno(`select estado_turno(token) from visitas where id = ${vis.id}`);
prueba("Diego (con cita) tiene 0 personas antes aunque llegó después", eDiego.antes === 0 && eDiego.de_cita === true, JSON.stringify(eDiego));
const eHugo = await uno(`select estado_turno($1)`, [w1.token]);
prueba("Hugo (sin cita) ahora tiene a Diego antes que él", eHugo.antes === 1, JSON.stringify(eHugo));
prueba("Marcar 'Llegó' dos veces no duplica", (await error(`select llegada_cita(${citaId})`))?.includes("ya no está pendiente"));
const otraId = await uno(`select id from citas where fecha = '2026-11-19'`);
prueba("No se puede marcar 'Llegó' una cita de otro día", (await error(`select llegada_cita(${otraId})`))?.includes("no es de hoy"));

seccion("CITAS VENCIDAS");
await reloj("2026-11-19 15:00"); // la cita de Diego del 19 a las 12:00 pasó hace 3 h
const ev = await uno(`select estado_cita(token) from citas where id = ${otraId}`);
prueba("El cliente ve su cita vencida como 'no vino'", ev.estado === "no_vino" && ev.cancelable === false, JSON.stringify(ev));
prueba("Ya no se puede cancelar una cita que pasó", (await uno(`select cancelar_cita(token) from citas where id = ${otraId}`)) === false);
await como(ADMIN);
const n = await uno(`select cerrar_citas_vencidas()`);
prueba("cerrar_citas_vencidas marca 'no vino' las citas viejas", n >= 1 && (await uno(`select estado from citas where id = ${otraId}`)) === "no_vino", "n=" + n);
prueba("Al vencerse, Diego puede volver a agendar (ya no cuenta para el límite de 2)",
  !!(await agendar("Diego", "5555555555", CORTE, null, "2026-11-20", "12:00"))?.token);

seccion("CAMBIOS EN EL EQUIPO Y EL HORARIO");
await reloj("2026-11-19 09:00");
await agendar("Kiko", "5514141414", CORTE, null, "2026-11-21", "13:00");
await agendar("Leo", "5515151515", CORTE, 2, "2026-11-21", "15:00");
prueba("Con 2 barberos, a las 13:00 del sábado hay un lugar más", (await libres("2026-11-21", CORTE)).includes("13:00"));
await db.exec(`update barberos set activo = false where nombre = 'Pedro'`);
prueba("Si Pedro se da de baja, las 13:00 se llenan (solo queda Juan)", !(await libres("2026-11-21", CORTE)).includes("13:00"));
prueba("Pedro ya no aparece para elegir", (await uno(`select barberos_publicos()`)).every((b) => b.nombre !== "Pedro"));
prueba("Ya no se puede apartar con Pedro", (await libres("2026-11-21", CORTE, 2)).length === 0);
await db.exec(`update barberos set activo = true where nombre = 'Pedro'`);
await db.exec(`update horario set abre = '12:00', cierra = '16:00' where dia = 6`);
L = await libres("2026-11-21", CORTE);
prueba("Si el sábado abre de 12 a 16, solo salen horarios en ese rango", L[0] === "12:00" && L.at(-1) === "15:30", L.join(" "));
prueba("Horario con cierre antes de apertura se rechaza", !!(await error(`update horario set abre = '18:00', cierra = '09:00' where dia = 1`)));

seccion("SEGURIDAD (permisos como Supabase)");
await como(null);
await db.exec(`set role anon`);
prueba("Un visitante no puede leer la tabla de citas (nombres y teléfonos)", (await q(`select * from citas`)).length === 0);
prueba("Un visitante no puede leer la fila de visitas", (await q(`select * from visitas`)).length === 0);
prueba("Un visitante sí puede leer el horario", (await q(`select * from horario`)).length === 7);
prueba("Un visitante no puede cambiar el horario", (await q(`update horario set abierto = false returning dia`)).length === 0);
prueba("Un visitante no puede llamar a las funciones internas", (await error(`select _cita_cabe('2026-11-25','12:00',30,null)`))?.includes("permission denied"));
prueba("Un visitante no puede marcar 'Llegó'", (await error(`select llegada_cita(1)`))?.includes("permission denied"));
prueba("Un visitante no puede insertar citas directo saltándose las reglas", !!(await error(`insert into citas (fecha,hora,duracion_min,cliente_nombre,telefono,servicio_id) values ('2026-11-25','03:00',30,'Hack','5500000000',1)`)));
prueba("Un visitante sí puede agendar por la función", !!(await agendar("Mia", "5516161616", CORTE, null, "2026-11-25", "12:00"))?.token);
await db.exec(`reset role`);
await como(BARB);
await db.exec(`set role authenticated`);
prueba("Un barbero sí ve las citas", (await q(`select * from citas`)).length > 0);
prueba("Un barbero no puede cambiar el horario", (await q(`update horario set abierto = false where dia = 1 returning dia`)).length === 0);
prueba("Un barbero no puede borrar citas", (await q(`delete from citas returning id`)).length === 0);
await db.exec(`reset role`);
await como(ADMIN);
await db.exec(`set role authenticated`);
prueba("El admin sí puede cambiar el horario", (await q(`update horario set abierto = true where dia = 0 returning dia`)).length === 1);
await db.exec(`reset role`);

// =========================================================
seccion("BLOQUEOS (vacaciones, comida, barbero que no viene)");
await reloj("2026-11-20 09:00");
await db.exec(`update horario set abre = '10:00', cierra = '20:00' where dia = 6`);
await db.exec(`update horario set abierto = false where dia = 0`); // la prueba del admin lo dejó abierto
await db.exec(`insert into bloqueos (fecha_ini, fecha_fin, motivo) values ('2026-11-24', '2026-11-24', 'Día festivo')`);
prueba("Día festivo de toda la barbería: no hay horarios ese día", (await libres("2026-11-24", CORTE)).length === 0);
const cerrados = await uno(`select dias_cerrados('2026-11-20', '2026-12-04')`);
prueba("dias_cerrados avisa al calendario del cliente que el 24 está cerrado", JSON.stringify(cerrados) === '["2026-11-24"]', JSON.stringify(cerrados));
prueba("No se puede agendar el día festivo",
  (await error(`select agendar_cita('Nora','5517171717',${CORTE},null,'2026-11-24','12:00')`))?.includes("no está disponible"));

await db.exec(`insert into bloqueos (fecha_ini, fecha_fin, hora_ini, hora_fin, motivo) values ('2026-11-25', '2026-11-25', '14:00', '15:00', 'Comida')`);
L = await libres("2026-11-25", CORTE);
prueba("Hora de comida 14–15: no salen 14:00 ni 14:30", !L.includes("14:00") && !L.includes("14:30") && L.includes("13:30") && L.includes("15:00"), L.join(" "));
prueba("Corte + barba (60 min) no puede empezar 13:30 porque choca con la comida", !(await libres("2026-11-25", CB)).includes("13:30"));
prueba("dias_cerrados no cuenta los bloqueos de unas horas", !(JSON.stringify(await uno(`select dias_cerrados('2026-11-25', '2026-11-25')`))).includes("25"));

await db.exec(`insert into bloqueos (fecha_ini, fecha_fin, barbero_id, motivo) values ('2026-11-26', '2026-11-26', 1, 'Juan descansa')`);
prueba("Juan descansa el 26: no tiene horarios", (await libres("2026-11-26", CORTE, 1)).length === 0);
prueba("Pedro sí tiene horarios el 26", (await libres("2026-11-26", CORTE, 2)).length === 20);
prueba("No se puede apartar con Juan el 26",
  (await error(`select agendar_cita('Olga','5518181818',${CORTE},1,'2026-11-26','12:00')`))?.includes("no está disponible"));
await agendar("Olga", "5518181818", CORTE, null, "2026-11-26", "12:00");
prueba("El 26 solo hay 1 lugar por hora (Juan no está): con 1 cita, las 12:00 se llenan", !(await libres("2026-11-26", CORTE)).includes("12:00"));
prueba("…y las 12:30 siguen libres", (await libres("2026-11-26", CORTE)).includes("12:30"));

seccion("BLOQUEOS: la fila del día también cierra");
await reloj("2026-11-25 14:20");
c = await uno(`select cola_publica()`);
prueba("Durante la comida aparece cerrado, con el motivo y que abre a las 15:00",
  c.abierto === false && c.motivo === "Comida" && c.proxima_fecha === "2026-11-25" && c.proxima_hora === "15:00", JSON.stringify(c));
prueba("Durante la comida no deja tomar turno", (await error(`select registrar_turno('Pau','5519191919',${CORTE})`))?.includes("Cerrado"));
await reloj("2026-11-25 15:00");
prueba("A las 15:00 ya está abierto otra vez", (await uno(`select cola_publica()`)).abierto === true);
await db.exec(`insert into bloqueos (fecha_ini, fecha_fin, motivo) values ('2026-12-01', '2026-12-05', 'Vacaciones')`);
await reloj("2026-12-02 11:00");
c = await uno(`select cola_publica()`);
prueba("Vacaciones del 1 al 5 (sábado): cerrado y abre el lunes 7 (el 6 es domingo)",
  c.abierto === false && c.motivo === "Vacaciones" && c.proxima_fecha === "2026-12-07" && c.proxima_hora === "10:00", JSON.stringify(c));

seccion("CITAS DESDE EL PANEL (llamadas y WhatsApp)");
await reloj("2026-11-20 09:00");
await como(null);
prueba("Sin sesión no se puede agendar desde el panel",
  (await error(`select agendar_cita_staff('Quique','5520202020',${CORTE},null,'2026-11-27','12:00')`))?.includes("Sin permiso"));
await como(BARB);
const idQ = await uno(`select agendar_cita_staff('Quique','5520202020',${CORTE},null,'2026-11-27','12:00')`);
prueba("Un barbero agenda una cita por teléfono", typeof idQ === "number");
await uno(`select agendar_cita_staff('Quique','5520202020',${CORTE},null,'2026-11-27','12:30')`);
await uno(`select agendar_cita_staff('Quique','5520202020',${CORTE},null,'2026-11-28','12:30')`);
prueba("Desde el panel no aplica el límite de 2 citas por teléfono (el personal decide)", true);
await uno(`select agendar_cita_staff('Rosa','5521212121',${CORTE},null,'2026-11-27','12:00')`);
prueba("Con 2 barberos, a las 12:00 del 27 ya no hay lugar ni para el personal",
  (await error(`select agendar_cita_staff('Sara','5522222222',${CORTE},null,'2026-11-27','12:00')`))?.includes("no está disponible"));
prueba("Un barbero no puede forzar una cita encimada",
  (await error(`select agendar_cita_staff('Sara','5522222222',${CORTE},null,'2026-11-27','12:00',true)`))?.includes("Solo el admin"));
await como(ADMIN);
prueba("El admin sí puede forzar una cita encimada (cliente especial)",
  typeof (await uno(`select agendar_cita_staff('Sara','5522222222',${CORTE},null,'2026-11-27','12:00',true)`)) === "number");

seccion("MOVER CITAS");
await como(BARB);
prueba("Mover la cita de Quique a las 16:00", (await uno(`select mover_cita(${idQ},'2026-11-27','16:00',null)`)) === true);
prueba("Las 16:00 ahora están ocupadas por Quique (sale un lugar menos)",
  (await uno(`select count(*)::int from citas where fecha='2026-11-27' and hora='16:00' and estado='agendada'`)) === 1);
await uno(`select agendar_cita_staff('Tito','5523232323',${CORTE},2,'2026-11-27','17:00')`);
await uno(`select agendar_cita_staff('Uri','5524242424',${CORTE},null,'2026-11-27','17:00')`);
prueba("No se puede mover a una hora llena",
  (await error(`select mover_cita(${idQ},'2026-11-27','17:00',null)`))?.includes("no está disponible"));
prueba("Mover a la misma hora que ya tiene no choca consigo misma", (await uno(`select mover_cita(${idQ},'2026-11-27','16:00',1)`)) === true);
prueba("No se puede mover una cita a un día festivo",
  (await error(`select mover_cita(${idQ},'2026-11-24','12:00',null)`))?.includes("no está disponible"));
const idCancel = await uno(`select id from citas where cliente_nombre = 'Rosa'`);
await db.exec(`update citas set estado = 'cancelada' where id = ${idCancel}`);
prueba("No se puede mover una cita cancelada", (await error(`select mover_cita(${idCancel},'2026-11-27','18:00',null)`))?.includes("pendientes"));

seccion("AVISO DE CITAS AFECTADAS AL BLOQUEAR");
await como(ADMIN);
const af = await uno(`select citas_en_bloqueo('2026-11-27','2026-11-27','15:30','17:30',null)`);
prueba("Antes de bloquear 15:30–17:30 del 27, avisa qué citas se afectan (Quique 16:00, Tito y Uri 17:00)",
  af.length === 3 && af.map((x) => x.hora).join(",") === "16:00,17:00,17:00", JSON.stringify(af));
const afJ = await uno(`select citas_en_bloqueo('2026-11-27','2026-11-27',null,null,1)`);
prueba("Si solo se bloquea a Juan, solo avisa de las citas de Juan", afJ.length === 1 && afJ[0].nombre === "Quique", JSON.stringify(afJ));

seccion("BLOQUEOS: permisos");
await como(BARB);
await db.exec(`set role authenticated`);
prueba("Un barbero ve los bloqueos", (await q(`select * from bloqueos`)).length > 0);
prueba("Un barbero puede bloquear su propio tiempo",
  (await q(`insert into bloqueos (fecha_ini, fecha_fin, barbero_id, motivo) values ('2026-11-28','2026-11-28',1,'Doctor') returning id`)).length === 1);
prueba("Un barbero no puede bloquear a otro barbero",
  !!(await error(`insert into bloqueos (fecha_ini, fecha_fin, barbero_id) values ('2026-11-28','2026-11-28',2)`)));
prueba("Un barbero no puede cerrar toda la barbería",
  !!(await error(`insert into bloqueos (fecha_ini, fecha_fin) values ('2026-11-28','2026-11-28')`)));
prueba("Un barbero no puede borrar el día festivo", (await q(`delete from bloqueos where barbero_id is null returning id`)).length === 0);
prueba("Un barbero puede quitar su propio bloqueo", (await q(`delete from bloqueos where motivo = 'Doctor' returning id`)).length === 1);
await db.exec(`reset role`);
await como(null);
await db.exec(`set role anon`);
prueba("Un visitante no ve los bloqueos (motivos privados)", (await q(`select * from bloqueos`)).length === 0);
prueba("Un visitante no puede agendar como personal", (await error(`select agendar_cita_staff('X','5500000000',1,null,'2026-11-27','12:00')`))?.includes("permission denied"));
prueba("Un visitante no puede mover citas", (await error(`select mover_cita(1,'2026-11-27','12:00',null)`))?.includes("permission denied"));
prueba("Un visitante sí puede consultar los días cerrados", Array.isArray(await uno(`select dias_cerrados('2026-11-20','2026-12-10')`)));
await db.exec(`reset role`);

seccion("SIN BARBEROS DADOS DE ALTA (como está tu Supabase hoy)");
await db.exec(`update barberos set activo = false`);
await reloj("2026-11-20 09:00");
prueba("Sin barberos activos igual se puede agendar (1 lugar por hora)", (await libres("2026-11-30", CORTE)).length === 20);
await agendar("Vale", "5525252525", CORTE, null, "2026-11-30", "12:00");
prueba("…y con una cita, esa hora se llena", !(await libres("2026-11-30", CORTE)).includes("12:00"));
await db.exec(`update barberos set activo = true`);

// =========================================================
seccion("CALENDARIO DE APERTURA (días con horario especial)");
await reloj("2026-11-20 09:00");
await db.exec(`delete from bloqueos; update horario set abierto = true, abre = '10:00', cierra = '20:00' where dia between 1 and 6; update horario set abierto = false where dia = 0;`);
let cal = await uno(`select calendario_publico('2026-11-20', '2026-11-26')`);
prueba("El calendario del cliente trae 7 días con su horario normal", cal.length === 7 && cal[0].abierto === true && cal[0].abre === "10:00" && cal[0].cierra === "20:00", JSON.stringify(cal[0]));
prueba("El domingo 22 sale cerrado en el calendario", cal.find((d) => d.fecha === "2026-11-22").abierto === false);

await db.exec(`insert into horario_especial (fecha, abierto) values ('2026-11-23', false)`);
await db.exec(`insert into horario_especial (fecha, abierto, abre, cierra, nota) values ('2026-11-28', true, '09:00', '15:00', 'Horario de sábado especial')`);
await db.exec(`insert into horario_especial (fecha, abierto, abre, cierra) values ('2026-11-29', true, '11:00', '16:00')`); // domingo que sí abre
cal = await uno(`select calendario_publico('2026-11-20', '2026-11-30')`);
const dia_ = (f) => cal.find((d) => d.fecha === f);
prueba("Alejandro cierra el lunes 23: el calendario lo muestra cerrado", dia_("2026-11-23").abierto === false && dia_("2026-11-23").especial === true);
prueba("Sábado 28 especial de 9:00 a 15:00", dia_("2026-11-28").abierto && dia_("2026-11-28").abre === "09:00" && dia_("2026-11-28").cierra === "15:00");
prueba("Domingo 29 que normalmente cierra, abre de 11:00 a 16:00", dia_("2026-11-29").abierto && dia_("2026-11-29").abre === "11:00");
prueba("Los días sin cambio no salen como especiales", dia_("2026-11-24").especial === false);

prueba("El lunes 23 cerrado no tiene horarios para citas", (await libres("2026-11-23", CORTE)).length === 0);
L = await libres("2026-11-28", CORTE);
prueba("El sábado 28 los horarios van de 9:00 a 14:30", L[0] === "09:00" && L.at(-1) === "14:30" && L.length === 12, L.join(" "));
L = await libres("2026-11-29", CORTE);
prueba("El domingo 29 especial sí tiene horarios (11:00 a 15:30)", L[0] === "11:00" && L.at(-1) === "15:30", L.join(" "));
prueba("No se puede agendar el lunes 23 cerrado",
  (await error(`select agendar_cita('Wen','5526262626',${CORTE},null,'2026-11-23','12:00')`))?.includes("no está disponible"));
prueba("Sí se puede agendar el domingo 29 especial", !!(await agendar("Wen", "5526262626", CORTE, null, "2026-11-29", "12:00"))?.token);

await db.exec(`insert into bloqueos (fecha_ini, fecha_fin, motivo) values ('2026-11-25', '2026-11-25', 'Festivo')`);
prueba("Un bloqueo de día completo también sale cerrado en el calendario",
  (await uno(`select calendario_publico('2026-11-25', '2026-11-25')`))[0].abierto === false);

seccion("CALENDARIO: la fila del día respeta el horario especial");
await reloj("2026-11-23 12:00");
c = await uno(`select cola_publica()`);
prueba("El lunes 23 cerrado: no acepta turnos y dice que abre el martes 24", c.abierto === false && c.proxima_fecha === "2026-11-24" && c.proxima_hora === "10:00", JSON.stringify(c));
await reloj("2026-11-28 15:30");
prueba("El sábado 28 a las 15:30 ya está cerrado (cerró a las 15:00)", (await uno(`select cola_publica()`)).abierto === false);
await reloj("2026-11-28 09:15");
prueba("El sábado 28 a las 9:15 ya está abierto (abrió a las 9:00)", (await uno(`select cola_publica()`)).abierto === true);
prueba("…y deja tomar turno", (await turno("Xavi", "5527272727")).turno >= 1);
await reloj("2026-11-28 14:50");
prueba("A las 14:50 del sábado especial ya no alcanza para un turno", (await error(`select registrar_turno('Yair','5528282828',${CORTE})`))?.includes("no alcanza"));
await reloj("2026-11-27 21:00");
c = await uno(`select cola_publica()`);
prueba("El viernes 27 en la noche dice que abre el sábado a las 9:00 (horario especial)", c.proxima_fecha === "2026-11-28" && c.proxima_hora === "09:00", JSON.stringify(c));

seccion("CALENDARIO: permisos");
await como(null);
await db.exec(`set role anon`);
prueba("Un visitante puede ver el calendario", (await uno(`select calendario_publico('2026-11-20','2026-11-30')`)).length === 11);
prueba("Un visitante no puede cambiar días", (await q(`update horario_especial set abierto = true returning fecha`)).length === 0);
prueba("Un visitante no puede agregar días especiales", !!(await error(`insert into horario_especial (fecha, abierto) values ('2026-12-10', false)`)));
await db.exec(`reset role`);
await como(BARB);
await db.exec(`set role authenticated`);
prueba("Un barbero no puede cambiar el calendario", !!(await error(`insert into horario_especial (fecha, abierto) values ('2026-12-10', false)`)));
await db.exec(`reset role`);
await como(ADMIN);
await db.exec(`set role authenticated`);
prueba("El admin sí puede cerrar un día", (await q(`insert into horario_especial (fecha, abierto) values ('2026-12-10', false) returning fecha`)).length === 1);
prueba("El admin puede regresar un día a su horario normal", (await q(`delete from horario_especial where fecha = '2026-12-10' returning fecha`)).length === 1);
prueba("No se puede guardar un día abierto sin horas", !!(await error(`insert into horario_especial (fecha, abierto) values ('2026-12-11', true)`)));
await db.exec(`reset role`);

// =========================================================
seccion("EQUIPO: comisión congelada en cada cobro");
await reloj("2026-11-24 12:00");
await como(ADMIN);
await db.exec(`update barberos set comision_pct = 50 where id = 1; delete from bloqueos;`);
const vId = async (nombre) => uno(`select id from visitas where cliente_nombre = $1 order by id desc limit 1`, [nombre]);
await uno(`select registrar_visita('Zoe', null, ${CORTE})`);
let z = await vId("Zoe");
await db.exec(`update visitas set estado = 'atendiendo', barbero_id = 1 where id = ${z}`);
prueba("Al pasar a 'atendiendo' se guarda la hora de inicio", (await uno(`select atendido_en is not null from visitas where id = ${z}`)) === true);
await db.exec(`update visitas set estado = 'espera' where id = ${z}`);
prueba("Si regresa a 'espera' se borra la hora de inicio", (await uno(`select atendido_en is null from visitas where id = ${z}`)) === true);
await db.exec(`update visitas set estado = 'cobrado', monto = 150, propina = 20, metodo_pago = 'efectivo' where id = ${z}`);
prueba("Al cobrar con Juan (50%) se guarda 50% en el cobro", Number(await uno(`select comision_pct from visitas where id = ${z}`)) === 50);
await db.exec(`update barberos set comision_pct = 40 where id = 1`);
prueba("Si después Juan baja a 40%, el cobro anterior sigue en 50%", Number(await uno(`select comision_pct from visitas where id = ${z}`)) === 50);
await uno(`select registrar_visita('Ana2', null, ${CORTE})`);
const z2 = await vId("Ana2");
await db.exec(`update visitas set estado = 'cobrado', barbero_id = 1, monto = 150, propina = 0, metodo_pago = 'tarjeta' where id = ${z2}`);
prueba("Un cobro nuevo de Juan ya usa 40%", Number(await uno(`select comision_pct from visitas where id = ${z2}`)) === 40);
await db.exec(`update visitas set barbero_id = 2 where id = ${z2}`);
prueba("Si el admin corrige el barbero de un cobro, toma el % del nuevo barbero (Pedro 50%)", Number(await uno(`select comision_pct from visitas where id = ${z2}`)) === 50);

await como(BARB);
await uno(`select registrar_visita('Beto2', null, ${CORTE})`);
const z3 = await vId("Beto2");
await db.exec(`set role authenticated`);
await q(`update visitas set comision_pct = 99 where id = ${z3}`);
await db.exec(`reset role`);
prueba("Un barbero no puede ponerse otra comisión a mano", (await uno(`select comision_pct from visitas where id = ${z3}`)) === null);
await db.exec(`set role authenticated`);
await q(`update visitas set estado = 'cobrado', barbero_id = 1, monto = 150, propina = 0, metodo_pago = 'efectivo', comision_pct = 99 where id = ${z3}`);
await db.exec(`reset role`);
prueba("…ni al cobrar: se usa el % real del barbero (40%)", Number(await uno(`select comision_pct from visitas where id = ${z3}`)) === 40);
await como(ADMIN);
prueba("Los cobros viejos (antes de este cambio) recibieron el % de su barbero", (await uno(`select count(*)::int from visitas where estado = 'cobrado' and barbero_id is not null and comision_pct is null`)) === 0);

// =========================================================
seccion("LLEGADA DEL CLIENTE CON CITA");
await como(null);
await reloj("2026-12-07 10:00");
const cA = await agendar("Mario Paz", "5530303030", CORTE, 1, "2026-12-08", "17:00");
const cB = await agendar("Nico Ríos", "5531313131", CORTE, null, "2026-12-08", "18:00");
const cC = await agendar("Omar Gil", "5532323232", CORTE, null, "2026-12-08", "12:00");
const cD = await agendar("Pepe Luna", "5533333330", CORTE, null, "2026-12-09", "12:00");
let ecA = await uno(`select estado_cita($1)`, [cA.token]);
prueba("Un día antes todavía no puede marcar que llegó", ecA.puede_llegar === false && ecA.llegar_desde === "16:15", JSON.stringify(ecA));
prueba("«Ya llegué» un día antes se rechaza", (await error(`select llegue_cita($1)`, [cA.token]))?.includes("no es de hoy"));

await reloj("2026-12-08 16:00");
prueba("Una hora antes: «Todavía es temprano»", (await error(`select llegue_cita($1)`, [cA.token]))?.includes("temprano"));
await turno("Walk", "5534343434");                            // alguien sin cita llegó antes
await reloj("2026-12-08 16:20");
prueba("A 40 min de su cita ya puede marcar que llegó", (await uno(`select estado_cita($1)`, [cA.token])).puede_llegar === true);
const lA = await uno(`select llegue_cita($1)`, [cA.token]);
prueba("«Ya llegué» lo pone en la fila y le da su turno", typeof lA.turno === "number" && !!lA.token, JSON.stringify(lA));
const tA = await uno(`select estado_turno($1)`, [lA.token]);
prueba("Entra con prioridad: nadie antes que él aunque había alguien sin cita", tA.de_cita === true && tA.antes === 0, JSON.stringify(tA));
prueba("Queda asignado a su barbero (Juan)", tA.barbero === "Juan");
ecA = await uno(`select estado_cita($1)`, [cA.token]);
prueba("Su cita ahora dice 'llegó' y trae el turno para seguirlo", ecA.estado === "llego" && ecA.turno === lA.turno && ecA.turno_token === lA.token);
const lA2 = await uno(`select llegue_cita($1)`, [cA.token]);
prueba("Tocar «Ya llegué» otra vez no lo duplica (regresa el mismo turno)", lA2.repetido === true && lA2.turno === lA.turno);
prueba("Solo hay una visita de Mario", (await uno(`select count(*)::int from visitas where cliente_nombre = 'Mario Paz'`)) === 1);

seccion("LLEGADA: el cliente con cita usa el QR de la entrada");
await reloj("2026-12-08 17:30");
const qB = await turno("Nico", "55 3131 3131");
prueba("Nico tiene cita a las 18:00 y toma turno con el QR: cuenta como llegada a su cita", qB.de_cita === true && qB.hora_cita === "18:00", JSON.stringify(qB));
prueba("Su cita quedó como 'llegó'", (await uno(`select estado_cita($1)`, [cB.token])).estado === "llego");
prueba("Y no queda dos veces en la fila", (await uno(`select count(*)::int from visitas where telefono = '5531313131' and fecha = '2026-12-08'`)) === 1);
prueba("Si vuelve a tomar turno, recibe el mismo", (await turno("Nico", "5531313131")).turno === qB.turno);
const qD = await turno("Pepe", "5533333330");
prueba("Pepe tiene cita MAÑANA: hoy toma turno normal (sin tocar su cita)", !qD.de_cita && (await uno(`select estado_cita($1)`, [cD.token])).estado === "agendada");

seccion("LLEGADA: tarde o sin permiso");
prueba("Omar llega 5 horas tarde a su cita de las 12:00: «Ya pasó tu hora»", (await error(`select llegue_cita($1)`, [cC.token]))?.includes("pasó tu hora"));
prueba("Un token inventado no hace nada", (await error(`select llegue_cita('00000000-0000-0000-0000-000000000000')`))?.includes("no existe"));
await db.exec(`set role anon`);
prueba("Un visitante no puede usar la función interna de pasar a la fila", (await error(`select _pasar_a_fila(1)`))?.includes("permission denied"));
prueba("Un visitante no puede usar el «Llegó» del personal", (await error(`select llegada_cita(1)`))?.includes("permission denied"));
await db.exec(`reset role`);
await como(BARB);
const cE = await agendar("Quino Paz", "5535353535", CORTE, null, "2026-12-08", "19:00");
prueba("El personal sigue pudiendo marcar «Llegó» desde el panel", typeof (await uno(`select llegada_cita(id) from citas where token = $1`, [cE.token])) === "number");
await como(null);

console.log(`\n${ok} pasaron, ${mal} fallaron`);
if (mal) { console.log("Fallaron:\n - " + fallas.join("\n - ")); process.exit(1); }
