-- =========================================================
--  Citas agendadas (día y hora) + reglas de la fila del día.
--  Pegar todo en Supabase > SQL Editor > Run (después de 06_productos.sql).
--  Se puede volver a ejecutar sin problema.
--
--  Citas:
--  - El cliente elige servicio, barbero (opcional), día y hora (cada 30 min).
--  - Nunca hay más citas encimadas que barberos activos; un barbero elegido
--    no tiene dos citas a la vez.
--  - Cuando el cliente llega, el personal toca "Llegó" y pasa a la fila
--    con PRIORIDAD sobre los que llegaron sin cita.
--  - Las citas que nadie atendió se marcan "no vino" 2 horas después.
--
--  Fila del día (turnos sin cita):
--  - Solo se puede tomar turno en horario y si alcanza el tiempo antes de cerrar.
--  - El mismo teléfono no puede tener dos turnos activos el mismo día.
--  - La espera estimada cuenta a los clientes con cita que van llegando.
-- =========================================================

-- Hora local del negocio (todas las reglas usan esta función)
create or replace function public.ahora_local() returns timestamp
language sql stable as $$
  select (now() at time zone 'America/Mexico_City')::timestamp
$$;

-- Minutos desde las 00:00 de una hora del día
create or replace function public._min(t time) returns int
language sql immutable as $$ select (extract(epoch from t) / 60)::int $$;

-- ---------- Horario de la barbería (0 = domingo … 6 = sábado) ----------
create table if not exists public.horario (
  dia      smallint primary key check (dia between 0 and 6),
  abierto  boolean not null default true,
  abre     time not null default '10:00',
  cierra   time not null default '20:00',
  check (cierra > abre)
);
insert into public.horario (dia, abierto)
values (0, false), (1, true), (2, true), (3, true), (4, true), (5, true), (6, true)
on conflict (dia) do nothing;

alter table public.horario enable row level security;
drop policy if exists horario_leer on public.horario;
drop policy if exists horario_admin on public.horario;
create policy horario_leer on public.horario for select to anon, authenticated using (true);
create policy horario_admin on public.horario for update to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

-- ---------- Citas ----------
create table if not exists public.citas (
  id              bigint generated always as identity primary key,
  fecha           date not null,
  hora            time not null,
  duracion_min    int  not null check (duracion_min between 5 and 240),
  cliente_nombre  text not null check (char_length(cliente_nombre) between 2 and 80),
  telefono        text not null check (char_length(telefono) between 10 and 20),
  servicio_id     bigint not null references public.servicios(id),
  barbero_id      bigint references public.barberos(id),   -- null = "cualquiera"
  estado          text not null default 'agendada'
                  check (estado in ('agendada','llego','cancelada','no_vino')),
  visita_id       bigint references public.visitas(id) on delete set null,
  token           uuid not null default gen_random_uuid() unique,
  creado_en       timestamptz not null default now()
);
create index if not exists citas_fecha_idx on public.citas (fecha, hora);
create index if not exists citas_tel_idx on public.citas (telefono) where estado = 'agendada';

alter table public.citas enable row level security;
drop policy if exists citas_staff_leer on public.citas;
drop policy if exists citas_staff_editar on public.citas;
drop policy if exists citas_admin on public.citas;
create policy citas_staff_leer on public.citas for select to authenticated
  using ((select public.mi_rol()) is not null);
create policy citas_staff_editar on public.citas for update to authenticated
  using ((select public.mi_rol()) is not null) with check ((select public.mi_rol()) is not null);
create policy citas_admin on public.citas for delete to authenticated
  using ((select public.mi_rol()) = 'admin');

do $$ begin
  alter publication supabase_realtime add table public.citas;
exception when duplicate_object then null; end $$;

-- Las visitas que vienen de una cita tienen prioridad en la fila
alter table public.visitas add column if not exists hora_cita time;

-- ---------- ¿Cabe una cita en ese horario? ----------
create or replace function public._cita_cabe(
  p_fecha date, p_hora time, p_dur int, p_barbero bigint, p_excluir bigint default null
) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  h    horario;
  ini  int := public._min(p_hora);
  fin  int := public._min(p_hora) + p_dur;
  encimadas int;
begin
  if p_fecha < hoy_local() or p_fecha > hoy_local() + 30 then return false; end if;
  if (p_fecha + p_hora) < ahora_local() + interval '15 minutes' then return false; end if;

  select * into h from horario where dia = extract(dow from p_fecha)::int;
  if not found or not h.abierto then return false; end if;
  if ini < public._min(h.abre) or fin > public._min(h.cierra) then return false; end if;

  if p_barbero is not null then
    if not exists (select 1 from barberos where id = p_barbero and activo) then return false; end if;
    if exists (
      select 1 from citas c
      where c.fecha = p_fecha and c.barbero_id = p_barbero and c.estado in ('agendada','llego')
        and c.id is distinct from p_excluir
        and public._min(c.hora) < fin and public._min(c.hora) + c.duracion_min > ini
    ) then return false; end if;
  end if;

  select count(*) into encimadas from citas c
  where c.fecha = p_fecha and c.estado in ('agendada','llego')
    and c.id is distinct from p_excluir
    and public._min(c.hora) < fin and public._min(c.hora) + c.duracion_min > ini;
  return encimadas < public._barberos_hoy();
end $$;

-- ---------- Público: barberos para elegir ----------
create or replace function public.barberos_publicos() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', id, 'nombre', nombre) order by nombre), '[]'::json)
  from barberos where activo
$$;

-- ---------- Público: horarios libres de un día (cada 30 min) ----------
create or replace function public.horarios_disponibles(
  p_fecha date, p_servicio_id bigint, p_barbero_id bigint default null
) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  h   horario;
  dur int;
begin
  select duracion_min into dur from servicios where id = p_servicio_id and activo;
  if dur is null then return '[]'::json; end if;
  select * into h from horario where dia = extract(dow from p_fecha)::int;
  if not found or not h.abierto then return '[]'::json; end if;
  return coalesce((
    select json_agg(to_char(g.ts, 'HH24:MI') order by g.ts)
    from generate_series(p_fecha + h.abre, p_fecha + h.cierra - make_interval(mins => dur), interval '30 minutes') g(ts)
    where public._cita_cabe(p_fecha, g.ts::time, dur, p_barbero_id)
  ), '[]'::json);
end $$;

-- ---------- Público: agendar ----------
create or replace function public.agendar_cita(
  p_nombre text, p_telefono text, p_servicio_id bigint, p_barbero_id bigint, p_fecha date, p_hora time
) returns json
language plpgsql security definer set search_path = public as $$
declare
  dur int;
  tel text := regexp_replace(coalesce(p_telefono, ''), '[^0-9]', '', 'g');
  r   citas;
begin
  p_nombre := btrim(coalesce(p_nombre, ''));
  if char_length(p_nombre) < 2 or char_length(p_nombre) > 80 then raise exception 'Nombre inválido'; end if;
  if char_length(tel) < 10 or char_length(tel) > 20 then raise exception 'Teléfono inválido'; end if;
  select duracion_min into dur from servicios where id = p_servicio_id and activo;
  if dur is null then raise exception 'Servicio inválido'; end if;
  if extract(minute from p_hora)::int % 30 <> 0 or extract(second from p_hora) <> 0 then
    raise exception 'Hora inválida';
  end if;

  -- Bloqueos: por teléfono (límite de citas) y por día (que nadie aparte el mismo hueco a la vez)
  perform pg_advisory_xact_lock(hashtext('cita-tel-' || tel));
  perform pg_advisory_xact_lock(hashtext('cita-' || p_fecha::text));

  if (select count(*) from citas where telefono = tel and estado = 'agendada'
        and (fecha + hora) >= ahora_local()) >= 2 then
    raise exception 'Ya tienes 2 citas agendadas';
  end if;
  if exists (select 1 from citas where telefono = tel and estado = 'agendada' and fecha = p_fecha) then
    raise exception 'Ya tienes una cita ese día';
  end if;
  if not public._cita_cabe(p_fecha, p_hora, dur, p_barbero_id) then
    raise exception 'Ese horario ya no está disponible';
  end if;

  insert into citas (fecha, hora, duracion_min, cliente_nombre, telefono, servicio_id, barbero_id)
  values (p_fecha, p_hora, dur, p_nombre, tel, p_servicio_id, p_barbero_id)
  returning * into r;
  return json_build_object('token', r.token, 'fecha', r.fecha, 'hora', to_char(r.fecha + r.hora, 'HH24:MI'));
end $$;

-- ---------- Público: consultar mi cita ----------
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
    'pasada',   (c.fecha + c.hora) < ahora_local() - interval '2 hours'
  )
  from citas c
  join servicios s on s.id = c.servicio_id
  left join barberos b on b.id = c.barbero_id
  where c.token = p_token
$$;

-- ---------- Público: cancelar mi cita (antes de la hora) ----------
create or replace function public.cancelar_cita(p_token uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update citas set estado = 'cancelada'
   where token = p_token and estado = 'agendada' and (fecha + hora) > ahora_local();
  return found;
end $$;

-- ---------- Personal: el cliente llegó → pasa a la fila con prioridad ----------
create or replace function public.llegada_cita(p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
declare
  c citas;
  v_turno int;
  v_visita bigint;
begin
  if public.mi_rol() is null then raise exception 'Sin permiso'; end if;
  select * into c from citas where id = p_id for update;
  if not found then raise exception 'La cita no existe'; end if;
  if c.estado <> 'agendada' then raise exception 'La cita ya no está pendiente'; end if;
  if c.fecha <> hoy_local() then raise exception 'La cita no es de hoy'; end if;

  v_turno := public.registrar_visita(c.cliente_nombre, c.telefono, c.servicio_id);
  update visitas set barbero_id = c.barbero_id, hora_cita = c.hora
   where fecha = hoy_local() and turno = v_turno
  returning id into v_visita;
  update citas set estado = 'llego', visita_id = v_visita where id = c.id;
  return v_turno;
end $$;

-- ---------- Personal: marcar "no vino" las citas vencidas (2 h después) ----------
create or replace function public.cerrar_citas_vencidas() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if public.mi_rol() is null then raise exception 'Sin permiso'; end if;
  update citas set estado = 'no_vino'
   where estado = 'agendada' and (fecha + hora) < ahora_local() - interval '2 hours';
  get diagnostics n = row_count;
  return n;
end $$;

-- =========================================================
--  Fila del día (reemplaza las funciones de 05_cliente.sql)
-- =========================================================

-- ¿Quién va antes que esta visita? Primero los que traen cita (por su hora),
-- luego los que llegaron sin cita (por número de turno).
create or replace function public._va_antes(w visitas, v visitas) returns boolean
language sql immutable as $$
  select case
    when w.hora_cita is not null and v.hora_cita is null then true
    when w.hora_cita is null and v.hora_cita is not null then false
    when w.hora_cita is not null then (w.hora_cita, w.turno) < (v.hora_cita, v.turno)
    else w.turno < v.turno
  end
$$;

-- Minutos de espera para una visita (o para alguien nuevo si p_visita es null).
-- Suma: los que van antes + la mitad de los que se atienden + las citas que
-- llegarán mientras tanto; todo repartido entre los barberos activos.
create or replace function public._espera(p_fecha date, p_visita bigint) returns int
language plpgsql stable security definer set search_path = public as $$
declare
  v      visitas;
  n      int := public._barberos_hoy();
  base   numeric;
  extra  numeric;
begin
  if p_visita is not null then select * into v from visitas where id = p_visita; end if;

  select coalesce(sum(case when w.estado = 'espera' and (p_visita is null or (w.id <> v.id and public._va_antes(w, v)))
                           then coalesce(s.duracion_min, 30) end), 0)
       + coalesce(sum(case when w.estado = 'atendiendo' then coalesce(s.duracion_min, 30) end), 0) / 2.0
    into base
  from visitas w left join servicios s on s.id = w.servicio_id
  where w.fecha = p_fecha;

  -- Los que traen cita no esperan a las citas que vienen después
  if p_visita is not null and v.hora_cita is not null then return ceil(base / n)::int; end if;

  select coalesce(sum(c.duracion_min), 0) into extra
  from citas c
  where c.fecha = p_fecha and c.estado = 'agendada'
    and (c.fecha + c.hora) >= ahora_local() - interval '15 minutes'
    and (c.fecha + c.hora) <  ahora_local() + make_interval(mins => ceil(base / n)::int + 30);

  return ceil((base + extra) / n)::int;
end $$;

-- Estado del negocio ahora: ¿abierto?, ¿todavía se aceptan turnos?
create or replace function public._abierto_hoy() returns json
language plpgsql stable security definer set search_path = public as $$
declare
  h      horario;
  ahora  timestamp := ahora_local();
  d      int;
  sig    horario;
  sig_f  date;
begin
  select * into h from horario where dia = extract(dow from ahora)::int;
  -- Próxima apertura (hoy más tarde o algún día de la semana que viene)
  for d in 0..7 loop
    select * into sig from horario where dia = extract(dow from ahora::date + d)::int and abierto;
    if found and (d > 0 or ahora::time < sig.abre) then sig_f := ahora::date + d; exit; end if;
  end loop;
  return json_build_object(
    'abierto', coalesce(h.abierto and ahora::time >= h.abre and ahora::time < h.cierra, false),
    'abre',    to_char(ahora::date + h.abre, 'HH24:MI'),
    'cierra',  to_char(ahora::date + h.cierra, 'HH24:MI'),
    'proxima_fecha', sig_f,
    'proxima_hora',  to_char(sig_f + sig.abre, 'HH24:MI')
  );
end $$;

create or replace function public.cola_publica() returns json
language plpgsql stable security definer set search_path = public as $$
declare
  est     json := public._abierto_hoy();
  v_min   int  := public._espera(hoy_local(), null);
  v_cierra time;
begin
  select h.cierra into v_cierra from horario h where h.dia = extract(dow from ahora_local())::int;
  return json_build_object(
    'esperando', (select count(*) from visitas where fecha = hoy_local() and estado = 'espera'),
    'minutos',   v_min,
    'abierto',   (est->>'abierto')::boolean,
    -- se aceptan turnos si está abierto y alcanza el tiempo (espera + 30 min) antes de cerrar
    'acepta',    (est->>'abierto')::boolean and ahora_local()::time + make_interval(mins => v_min + 30) <= v_cierra,
    'abre',      est->>'abre',
    'cierra',    est->>'cierra',
    'proxima_fecha', est->>'proxima_fecha',
    'proxima_hora',  est->>'proxima_hora'
  );
end $$;

-- Registrarse en la fila (público)
create or replace function public.registrar_turno(
  p_nombre text, p_telefono text, p_servicio_id bigint
) returns json
language plpgsql security definer set search_path = public as $$
declare
  tel   text := nullif(regexp_replace(coalesce(p_telefono, ''), '[^0-9+]', '', 'g'), '');
  ya    visitas;
  est   json;
  h     horario;
  dur   int;
  v_turno int;
  v_token uuid;
begin
  -- Mismo teléfono con un turno activo hoy: se le regresa ese mismo turno
  if tel is not null then
    select * into ya from visitas
     where fecha = hoy_local() and telefono = left(tel, 20) and estado in ('espera','atendiendo')
     order by turno desc limit 1;
    if found then return json_build_object('turno', ya.turno, 'token', ya.token, 'repetido', true); end if;
  end if;

  est := public._abierto_hoy();
  if not (est->>'abierto')::boolean then raise exception 'Cerrado'; end if;
  select * into h from horario where dia = extract(dow from ahora_local())::int;
  select coalesce(duracion_min, 30) into dur from servicios where id = p_servicio_id and activo;
  if ahora_local()::time + make_interval(mins => public._espera(hoy_local(), null) + coalesce(dur, 30)) > h.cierra then
    raise exception 'Ya no alcanza el tiempo hoy';
  end if;

  v_turno := public.registrar_visita(p_nombre, p_telefono, p_servicio_id);
  select token into v_token from visitas where fecha = hoy_local() and turno = v_turno;
  return json_build_object('turno', v_turno, 'token', v_token);
end $$;

-- Consultar mi turno
create or replace function public.estado_turno(p_token uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'turno',     v.turno,
    'fecha',     v.fecha,
    'es_hoy',    v.fecha = hoy_local(),
    'estado',    v.estado,
    'nombre',    split_part(v.cliente_nombre, ' ', 1),
    'servicio',  s.nombre,
    'precio',    s.precio,
    'barbero',   b.nombre,
    'de_cita',   v.hora_cita is not null,
    'antes',     (select count(*) from visitas w
                   where w.fecha = v.fecha and w.estado = 'espera' and w.id <> v.id and public._va_antes(w, v)),
    'minutos',   case when v.estado = 'espera' then public._espera(v.fecha, v.id) end
  )
  from visitas v
  left join servicios s on s.id = v.servicio_id
  left join barberos  b on b.id = v.barbero_id
  where v.token = p_token
$$;

-- ---------- Permisos ----------
revoke all on function public._cita_cabe(date,time,int,bigint,bigint) from public, anon, authenticated;
revoke all on function public._espera(date,bigint) from public, anon, authenticated;
revoke all on function public._abierto_hoy() from public, anon, authenticated;
revoke all on function public.barberos_publicos() from public;
revoke all on function public.horarios_disponibles(date,bigint,bigint) from public;
revoke all on function public.agendar_cita(text,text,bigint,bigint,date,time) from public;
revoke all on function public.estado_cita(uuid) from public;
revoke all on function public.cancelar_cita(uuid) from public;
revoke all on function public.llegada_cita(bigint) from public, anon;
revoke all on function public.cerrar_citas_vencidas() from public, anon;
revoke all on function public.cola_publica() from public;
revoke all on function public.registrar_turno(text,text,bigint) from public;
revoke all on function public.estado_turno(uuid) from public;
grant execute on function public.barberos_publicos() to anon, authenticated;
grant execute on function public.horarios_disponibles(date,bigint,bigint) to anon, authenticated;
grant execute on function public.agendar_cita(text,text,bigint,bigint,date,time) to anon, authenticated;
grant execute on function public.estado_cita(uuid) to anon, authenticated;
grant execute on function public.cancelar_cita(uuid) to anon, authenticated;
grant execute on function public.llegada_cita(bigint) to authenticated;
grant execute on function public.cerrar_citas_vencidas() to authenticated;
grant execute on function public.cola_publica() to anon, authenticated;
grant execute on function public.registrar_turno(text,text,bigint) to anon, authenticated;
grant execute on function public.estado_turno(uuid) to anon, authenticated;
