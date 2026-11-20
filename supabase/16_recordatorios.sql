-- =========================================================
--  Recordatorios de cita y «Confirmar asistencia».
--  Pegar todo en Supabase > SQL Editor > Run (después de 15_notificaciones.sql).
--  Se puede volver a ejecutar sin problema.
--
--  - El cliente confirma su asistencia desde el enlace de su cita.
--  - El cliente puede pedir que le avisen en su celular (notificación push):
--    le llega un aviso ~24 horas antes y otro 2 horas antes, solos.
--  - Para los demás, el panel arma los WhatsApp de recordatorio de mañana
--    y marca a quién ya se le mandó.
--  Necesita la función «avisos» (supabase/functions/avisos/index.ts, versión nueva).
-- =========================================================

-- ---------- Marcas en cada cita ----------
alter table public.citas add column if not exists confirmada_en timestamptz;   -- el cliente confirmó que viene
alter table public.citas add column if not exists recordada_en  timestamptz;   -- el personal le mandó el WhatsApp
alter table public.citas add column if not exists aviso_celular boolean not null default false;  -- pidió avisos en su celular
alter table public.citas add column if not exists aviso24_en    timestamptz;   -- ya se mandó el aviso del día anterior
alter table public.citas add column if not exists aviso2_en     timestamptz;   -- ya se mandó el aviso de 2 horas antes

-- Si la cita cambia de día u hora, los avisos automáticos se vuelven a mandar con la hora nueva
create or replace function public._reiniciar_avisos() returns trigger
language plpgsql as $$
begin
  if (new.fecha, new.hora) is distinct from (old.fecha, old.hora) then
    new.aviso24_en := null; new.aviso2_en := null; new.recordada_en := null;
  end if;
  return new;
end $$;
drop trigger if exists reiniciar_avisos on public.citas;
create trigger reiniciar_avisos before update on public.citas
  for each row execute function public._reiniciar_avisos();

-- ---------- Celulares de clientes que pidieron aviso (uno o varios por cita) ----------
create table if not exists public.cita_push (
  id        bigint generated always as identity primary key,
  cita_id   bigint not null references public.citas(id) on delete cascade,
  endpoint  text not null check (char_length(endpoint) between 10 and 1000),
  p256dh    text not null check (char_length(p256dh) between 10 and 200),
  auth      text not null check (char_length(auth) between 10 and 100),
  creado_en timestamptz not null default now(),
  unique (cita_id, endpoint)
);
alter table public.cita_push enable row level security;   -- sin reglas: nadie la lee desde la página (solo la función «avisos»)

-- ---------- Lo que el cliente puede hacer con el enlace de su cita ----------
-- Confirmar asistencia (solo citas apartadas que todavía no pasan)
create or replace function public.confirmar_cita(p_token uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update citas set confirmada_en = coalesce(confirmada_en, now())
   where token = p_token and estado = 'agendada' and (fecha + hora) > ahora_local();
  return found;
end $$;

-- Pedir avisos en este celular
create or replace function public.suscribir_cita(p_token uuid, p_endpoint text, p_p256dh text, p_auth text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  select id into v_id from citas where token = p_token and estado = 'agendada' and (fecha + hora) > ahora_local();
  if v_id is null then return false; end if;
  if p_endpoint !~ '^https://' then raise exception 'Suscripción inválida'; end if;
  if (select count(*) from cita_push where cita_id = v_id) >= 5 then raise exception 'Demasiados celulares para esta cita'; end if;
  insert into cita_push (cita_id, endpoint, p256dh, auth) values (v_id, p_endpoint, p_p256dh, p_auth)
  on conflict (cita_id, endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth;
  update citas set aviso_celular = true where id = v_id;
  return true;
end $$;

revoke all on function public.confirmar_cita(uuid) from public;
revoke all on function public.suscribir_cita(uuid, text, text, text) from public;
grant execute on function public.confirmar_cita(uuid) to anon, authenticated;
grant execute on function public.suscribir_cita(uuid, text, text, text) to anon, authenticated;

-- Consultar mi cita: igual que antes, más si ya confirmó y si tiene avisos en el celular
create or replace function public.estado_cita(p_token uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'fecha',    c.fecha,
    'hora',     to_char(c.fecha + c.hora, 'HH24:MI'),
    'duracion', c.duracion_min,
    'estado',   case when c.estado = 'agendada' and (c.fecha + c.hora) < ahora_local() - interval '2 hours'
                     then 'no_vino' else c.estado end,
    'nombre',   split_part(c.cliente_nombre, ' ', 1),
    'servicio', s.nombre,
    'precio',   s.precio,
    'barbero',  b.nombre,
    'cancelable', c.estado = 'agendada' and (c.fecha + c.hora) > ahora_local(),
    'pasada',   (c.fecha + c.hora) < ahora_local() - interval '2 hours',
    'puede_llegar', public._puede_llegar(c),
    'llegar_desde', to_char((c.fecha + c.hora) - interval '45 minutes', 'HH24:MI'),
    'turno',    v.turno,
    'turno_token', v.token,
    'turno_estado', v.estado,
    'confirmada', c.confirmada_en is not null,
    'aviso_celular', c.aviso_celular
  )
  from citas c
  join servicios s on s.id = c.servicio_id
  left join barberos b on b.id = c.barbero_id
  left join visitas v on v.id = c.visita_id
  where c.token = p_token
$$;
revoke all on function public.estado_cita(uuid) from public;
grant execute on function public.estado_cita(uuid) to anon, authenticated;

-- ---------- Avisos automáticos: cada 10 minutos revisa si hay alguno que mandar ----------
create or replace function public._lanzar_recordatorios() returns void
language plpgsql security definer set search_path = public as $$
declare v_url text; v_sec text;
begin
  -- Solo llama a la función si hay citas con aviso pendiente (así no gasta llamadas de más)
  if not exists (
    select 1 from citas c
     where c.estado = 'agendada' and c.aviso_celular
       and (c.fecha + c.hora) > ahora_local()
       and ((c.aviso24_en is null and (c.fecha + c.hora) <= ahora_local() + interval '24 hours 10 minutes')
         or (c.aviso2_en  is null and (c.fecha + c.hora) <= ahora_local() + interval '2 hours 10 minutes'))
  ) then return; end if;
  select valor into v_url from privado.ajustes where clave = 'avisos_url';
  select valor into v_sec from privado.ajustes where clave = 'avisos_secreto';
  if v_url is null or v_sec is null then return; end if;
  perform net.http_post(
    url     := v_url,
    body    := jsonb_build_object('tipo', 'recordatorios'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-avisos-secreto', v_sec)
  );
exception when others then
  null;   -- sin pg_net o con error: no pasa nada, se intenta en la siguiente vuelta
end $$;
revoke all on function public._lanzar_recordatorios() from public, anon, authenticated;

-- pg_cron: el reloj que corre la revisión cada 10 minutos
do $$ begin
  create extension if not exists pg_cron;
exception when others then
  raise notice 'No se pudo activar pg_cron: %', sqlerrm;
end $$;
do $$ begin
  perform cron.schedule('recordatorios-citas', '*/10 * * * *', 'select public._lanzar_recordatorios()');
exception when others then
  raise notice 'No se pudo programar la revisión de recordatorios: %', sqlerrm;
end $$;
