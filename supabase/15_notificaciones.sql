-- =========================================================
--  Notificaciones al celular de los barberos (aunque el panel esté cerrado).
--  Pegar todo en Supabase > SQL Editor > Run (después de 14_tiempo_real.sql).
--  Se puede volver a ejecutar sin problema.
--
--  Cuándo avisa (a cada barbero solo lo suyo; las citas con «cualquier
--  barbero» le llegan a todo el equipo):
--    - le agendaron una cita (el cliente o alguien desde el panel)
--    - se canceló una cita suya
--    - se movió de día u hora, o se la pasaron a otro barbero
--  Quien hizo el cambio desde el panel no recibe aviso de su propio cambio.
--
--  Cómo funciona:
--    1) Cada celular que toca «Activar avisos» en el panel guarda aquí su
--       suscripción (la dirección a la que el navegador recibe avisos).
--    2) Cuando cambia una cita, la base de datos llama a la función «avisos»
--       (supabase/functions/avisos/index.ts) con el número de cita, sin
--       nombres ni teléfonos. La función lee la cita y manda el aviso.
--    3) Si algo falla, la cita se guarda igual: el aviso nunca la detiene.
-- =========================================================

-- pg_net: permite que la base de datos llame a la función al guardar una cita
do $$ begin
  create extension if not exists pg_net;
exception when others then
  raise notice 'No se pudo activar pg_net: %', sqlerrm;
end $$;

-- ---------- Ajustes privados (no se ven desde la página) ----------
create schema if not exists privado;
revoke all on schema privado from public, anon, authenticated;
create table if not exists privado.ajustes (
  clave text primary key,
  valor text not null
);
revoke all on privado.ajustes from public, anon, authenticated;
-- Sin reglas = nadie entra desde la página; las funciones de abajo sí (corren como dueño)
alter table privado.ajustes enable row level security;

-- Contraseña interna entre la base de datos y la función «avisos» (se crea sola)
insert into privado.ajustes (clave, valor)
values ('avisos_secreto', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
on conflict (clave) do nothing;
-- Dirección de la función (la URL del proyecto es pública; está también en config.js)
insert into privado.ajustes (clave, valor)
values ('avisos_url', 'https://iqvdfhjonrricibdwchc.supabase.co/functions/v1/avisos')
on conflict (clave) do nothing;

-- Solo la función «avisos» (con la llave de servidor) lee y guarda ajustes privados
create or replace function public.ajuste_privado(p_clave text) returns text
language sql stable security definer set search_path = privado as $$
  select valor from privado.ajustes where clave = p_clave
$$;
-- Guarda un ajuste solo si no existía y devuelve el que quedó (si dos llamadas
-- crean las llaves al mismo tiempo, las dos se quedan con las mismas)
create or replace function public.crear_ajuste_privado(p_clave text, p_valor text) returns text
language plpgsql security definer set search_path = privado as $$
begin
  insert into privado.ajustes (clave, valor) values (p_clave, p_valor) on conflict (clave) do nothing;
  return (select valor from privado.ajustes where clave = p_clave);
end $$;
drop function if exists public.guardar_ajuste_privado(text, text);
revoke all on function public.ajuste_privado(text) from public, anon, authenticated;
revoke all on function public.crear_ajuste_privado(text, text) from public, anon, authenticated;
do $$ begin
  grant execute on function public.ajuste_privado(text) to service_role;
  grant execute on function public.crear_ajuste_privado(text, text) to service_role;
exception when undefined_object then null; end $$;

-- ---------- Suscripciones: un registro por celular/navegador ----------
create table if not exists public.push_suscripciones (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  endpoint    text not null unique check (char_length(endpoint) between 10 and 1000),
  p256dh      text not null check (char_length(p256dh) between 10 and 200),
  auth        text not null check (char_length(auth) between 10 and 100),
  agente      text check (agente is null or char_length(agente) <= 300),
  creado_en   timestamptz not null default now()
);
create index if not exists push_suscripciones_user_idx on public.push_suscripciones (user_id);
alter table public.push_suscripciones enable row level security;
drop policy if exists push_propias on public.push_suscripciones;
-- Cada quien solo ve las suyas (para saber si este celular ya tiene avisos)
create policy push_propias on public.push_suscripciones for select to authenticated
  using (user_id = auth.uid());

-- Guardar la suscripción de este celular. Si el celular lo usaba otra cuenta,
-- pasa a la cuenta que lo activa ahora (así no le llegan avisos a quien no es).
create or replace function public.guardar_suscripcion(p_endpoint text, p_p256dh text, p_auth text, p_agente text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.mi_rol() is null then raise exception 'Solo el personal puede activar avisos'; end if;
  if p_endpoint !~ '^https://' then raise exception 'Suscripción inválida'; end if;
  insert into push_suscripciones (user_id, endpoint, p256dh, auth, agente)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_agente, 300))
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
        agente = excluded.agente, creado_en = now();
end $$;
create or replace function public.borrar_suscripcion(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from push_suscripciones where endpoint = p_endpoint and user_id = auth.uid()
$$;
revoke all on function public.guardar_suscripcion(text, text, text, text) from public, anon;
revoke all on function public.borrar_suscripcion(text) from public, anon;
grant execute on function public.guardar_suscripcion(text, text, text, text) to authenticated;
grant execute on function public.borrar_suscripcion(text) to authenticated;

-- ---------- Aviso al cambiar una cita ----------
create or replace function public._avisar_cita() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_tipo text;
  v_url  text;
  v_sec  text;
begin
  if tg_op = 'INSERT' then
    if new.estado = 'agendada' then v_tipo := 'nueva'; end if;
  elsif old.estado = 'agendada' and new.estado = 'cancelada' then
    v_tipo := 'cancelada';
  elsif old.estado = 'agendada' and new.estado = 'agendada'
        and (new.fecha, new.hora, new.barbero_id) is distinct from (old.fecha, old.hora, old.barbero_id) then
    v_tipo := 'movida';
  end if;
  if v_tipo is null then return null; end if;

  begin
    select valor into v_url from privado.ajustes where clave = 'avisos_url';
    select valor into v_sec from privado.ajustes where clave = 'avisos_secreto';
    if v_url is null or v_sec is null then return null; end if;
    -- Solo números y fechas: nada de nombres ni teléfonos sale de la base de datos aquí
    perform net.http_post(
      url     := v_url,
      body    := jsonb_build_object(
                   'tipo', v_tipo, 'cita', new.id, 'actor', auth.uid(),
                   'antes', case when tg_op = 'UPDATE'
                                 then jsonb_build_object('fecha', old.fecha, 'hora', old.hora, 'barbero_id', old.barbero_id) end),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-avisos-secreto', v_sec)
    );
  exception when others then
    null;   -- sin pg_net o con error: la cita se guarda igual
  end;
  return null;
end $$;
revoke all on function public._avisar_cita() from public, anon, authenticated;

drop trigger if exists avisar_barbero on public.citas;
create trigger avisar_barbero after insert or update on public.citas
  for each row execute function public._avisar_cita();
