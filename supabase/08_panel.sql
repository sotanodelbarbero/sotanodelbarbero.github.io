-- =========================================================
--  Panel más completo: bloqueos de agenda, citas desde el panel
--  y mover citas.
--  Pegar todo en Supabase > SQL Editor > Run (después de 07_citas.sql).
--  Se puede volver a ejecutar sin problema.
--
--  Bloqueos: vacaciones, días festivos, hora de comida o un barbero que
--  no viene. Pueden ser de todo el día o de unas horas, de uno o varios
--  días seguidos, para toda la barbería o para un solo barbero.
-- =========================================================

create table if not exists public.bloqueos (
  id          bigint generated always as identity primary key,
  fecha_ini   date not null,
  fecha_fin   date not null,
  hora_ini    time,                 -- vacío = todo el día
  hora_fin    time,
  barbero_id  bigint references public.barberos(id) on delete cascade,  -- vacío = toda la barbería
  motivo      text check (motivo is null or char_length(motivo) <= 80),
  creado_en   timestamptz not null default now(),
  creado_por  uuid default auth.uid() references auth.users(id),
  check (fecha_fin >= fecha_ini),
  check ((hora_ini is null and hora_fin is null) or (hora_ini is not null and hora_fin is not null and hora_fin > hora_ini))
);
create index if not exists bloqueos_fechas_idx on public.bloqueos (fecha_ini, fecha_fin);

alter table public.bloqueos enable row level security;
drop policy if exists bloqueos_leer on public.bloqueos;
drop policy if exists bloqueos_admin on public.bloqueos;
drop policy if exists bloqueos_barbero_crear on public.bloqueos;
drop policy if exists bloqueos_barbero_borrar on public.bloqueos;
-- Todo el personal ve los bloqueos
create policy bloqueos_leer on public.bloqueos for select to authenticated
  using ((select public.mi_rol()) is not null);
-- El admin crea, cambia y borra cualquiera
create policy bloqueos_admin on public.bloqueos for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');
-- Un barbero solo bloquea (y desbloquea) su propio tiempo
create policy bloqueos_barbero_crear on public.bloqueos for insert to authenticated
  with check ((select public.mi_rol()) = 'barbero' and barbero_id = (select public.mi_barbero()));
create policy bloqueos_barbero_borrar on public.bloqueos for delete to authenticated
  using ((select public.mi_rol()) = 'barbero' and barbero_id = (select public.mi_barbero()));

do $$ begin
  alter publication supabase_realtime add table public.bloqueos;
exception when duplicate_object then null; end $$;

-- ¿Hay un bloqueo que toque ese rato? (p_barbero null = bloqueo de toda la barbería)
create or replace function public._bloqueado(p_barbero bigint, p_fecha date, p_ini int, p_fin int) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from bloqueos b
    where p_fecha between b.fecha_ini and b.fecha_fin
      and b.barbero_id is not distinct from p_barbero
      and (b.hora_ini is null or (public._min(b.hora_ini) < p_fin and public._min(b.hora_fin) > p_ini))
  )
$$;

-- ---------- ¿Cabe una cita? (ahora respeta los bloqueos) ----------
create or replace function public._cita_cabe(
  p_fecha date, p_hora time, p_dur int, p_barbero bigint, p_excluir bigint default null
) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  h    horario;
  ini  int := public._min(p_hora);
  fin  int := public._min(p_hora) + p_dur;
  activos int;
  libres  int;
  encimadas int;
begin
  if p_fecha < hoy_local() or p_fecha > hoy_local() + 30 then return false; end if;
  if (p_fecha + p_hora) < ahora_local() + interval '15 minutes' then return false; end if;

  select * into h from horario where dia = extract(dow from p_fecha)::int;
  if not found or not h.abierto then return false; end if;
  if ini < public._min(h.abre) or fin > public._min(h.cierra) then return false; end if;

  -- Toda la barbería bloqueada en ese rato
  if public._bloqueado(null, p_fecha, ini, fin) then return false; end if;

  if p_barbero is not null then
    if not exists (select 1 from barberos where id = p_barbero and activo) then return false; end if;
    if public._bloqueado(p_barbero, p_fecha, ini, fin) then return false; end if;
    if exists (
      select 1 from citas c
      where c.fecha = p_fecha and c.barbero_id = p_barbero and c.estado in ('agendada','llego')
        and c.id is distinct from p_excluir
        and public._min(c.hora) < fin and public._min(c.hora) + c.duracion_min > ini
    ) then return false; end if;
  end if;

  -- Cupo = barberos activos que no están bloqueados en ese rato
  -- (si todavía no hay barberos dados de alta, se cuenta 1 lugar)
  select count(*) into activos from barberos where activo;
  select count(*) into libres from barberos b
   where b.activo and not public._bloqueado(b.id, p_fecha, ini, fin);
  if activos = 0 then libres := 1; end if;

  select count(*) into encimadas from citas c
  where c.fecha = p_fecha and c.estado in ('agendada','llego')
    and c.id is distinct from p_excluir
    and public._min(c.hora) < fin and public._min(c.hora) + c.duracion_min > ini;
  return encimadas < libres;
end $$;

-- ---------- Días cerrados por bloqueo (para el calendario del cliente) ----------
create or replace function public.dias_cerrados(p_desde date, p_hasta date) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(distinct d::date order by d::date), '[]'::json)
  from bloqueos b, generate_series(greatest(b.fecha_ini, p_desde), least(b.fecha_fin, p_hasta, p_desde + 60), interval '1 day') d
  where b.barbero_id is null and b.hora_ini is null
    and b.fecha_fin >= p_desde and b.fecha_ini <= p_hasta
$$;

-- ---------- ¿Está abierto ahora? (ahora respeta los bloqueos) ----------
create or replace function public._abierto_hoy() returns json
language plpgsql stable security definer set search_path = public as $$
declare
  h      horario;
  ahora  timestamp := ahora_local();
  t      int := public._min(ahora_local()::time);
  bl     bloqueos;
  d      int;
  f      date;
  sig    horario;
  sig_f  date;
  sig_h  time;
begin
  select * into h from horario where dia = extract(dow from ahora)::int;
  -- Bloqueo de toda la barbería que cubre este momento
  select * into bl from bloqueos b
   where b.barbero_id is null and ahora::date between b.fecha_ini and b.fecha_fin
     and (b.hora_ini is null or (t >= public._min(b.hora_ini) and t < public._min(b.hora_fin)))
   order by b.hora_ini nulls first limit 1;

  -- Próxima apertura: hoy más tarde, o el siguiente día abierto y sin bloqueo de día completo
  for d in 0..45 loop
    f := ahora::date + d;
    select * into sig from horario where dia = extract(dow from f)::int and abierto;
    continue when not found;
    continue when exists (select 1 from bloqueos b where b.barbero_id is null and b.hora_ini is null
                           and f between b.fecha_ini and b.fecha_fin);
    if d = 0 then
      if ahora::time < sig.abre then sig_h := sig.abre;
      elsif bl.id is not null and bl.hora_fin is not null and bl.hora_fin < sig.cierra then sig_h := bl.hora_fin;
      else continue;
      end if;
    else
      sig_h := sig.abre;
    end if;
    sig_f := f; exit;
  end loop;

  return json_build_object(
    'abierto', coalesce(h.abierto and ahora::time >= h.abre and ahora::time < h.cierra, false) and bl.id is null,
    'abre',    to_char(ahora::date + h.abre, 'HH24:MI'),
    'cierra',  to_char(ahora::date + h.cierra, 'HH24:MI'),
    'motivo',  bl.motivo,
    'proxima_fecha', sig_f,
    'proxima_hora',  to_char(sig_f + sig_h, 'HH24:MI')
  );
end $$;

-- cola_publica: igual que en 07, pero pasa el motivo del cierre
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
    'acepta',    (est->>'abierto')::boolean and ahora_local()::time + make_interval(mins => v_min + 30) <= v_cierra,
    'abre',      est->>'abre',
    'cierra',    est->>'cierra',
    'motivo',    est->>'motivo',
    'proxima_fecha', est->>'proxima_fecha',
    'proxima_hora',  est->>'proxima_hora'
  );
end $$;

-- ---------- Personal: agendar una cita por el cliente (llamada / WhatsApp) ----------
-- p_forzar (solo admin): aparta aunque no haya lugar o esté fuera de horario.
create or replace function public.agendar_cita_staff(
  p_nombre text, p_telefono text, p_servicio_id bigint, p_barbero_id bigint,
  p_fecha date, p_hora time, p_forzar boolean default false
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  dur int;
  tel text := regexp_replace(coalesce(p_telefono, ''), '[^0-9]', '', 'g');
  v_id bigint;
begin
  if public.mi_rol() is null then raise exception 'Sin permiso'; end if;
  if p_forzar and public.mi_rol() <> 'admin' then raise exception 'Solo el admin puede forzar una cita'; end if;
  p_nombre := btrim(coalesce(p_nombre, ''));
  if char_length(p_nombre) < 2 or char_length(p_nombre) > 80 then raise exception 'Nombre inválido'; end if;
  if char_length(tel) < 10 or char_length(tel) > 20 then raise exception 'Teléfono inválido'; end if;
  select duracion_min into dur from servicios where id = p_servicio_id and activo;
  if dur is null then raise exception 'Servicio inválido'; end if;

  perform pg_advisory_xact_lock(hashtext('cita-' || p_fecha::text));
  if not p_forzar and not public._cita_cabe(p_fecha, p_hora, dur, p_barbero_id) then
    raise exception 'Ese horario no está disponible';
  end if;

  insert into citas (fecha, hora, duracion_min, cliente_nombre, telefono, servicio_id, barbero_id)
  values (p_fecha, p_hora, dur, p_nombre, tel, p_servicio_id, p_barbero_id)
  returning id into v_id;
  return v_id;
end $$;

-- ---------- Personal: mover una cita a otro día, hora o barbero ----------
create or replace function public.mover_cita(
  p_id bigint, p_fecha date, p_hora time, p_barbero_id bigint, p_forzar boolean default false
) returns boolean
language plpgsql security definer set search_path = public as $$
declare c citas;
begin
  if public.mi_rol() is null then raise exception 'Sin permiso'; end if;
  if p_forzar and public.mi_rol() <> 'admin' then raise exception 'Solo el admin puede forzar una cita'; end if;
  perform pg_advisory_xact_lock(hashtext('cita-' || p_fecha::text));
  select * into c from citas where id = p_id for update;
  if not found then raise exception 'La cita no existe'; end if;
  if c.estado <> 'agendada' then raise exception 'Solo se mueven citas pendientes'; end if;
  if not p_forzar and not public._cita_cabe(p_fecha, p_hora, c.duracion_min, p_barbero_id, p_id) then
    raise exception 'Ese horario no está disponible';
  end if;
  update citas set fecha = p_fecha, hora = p_hora, barbero_id = p_barbero_id where id = p_id;
  return true;
end $$;

-- ---------- Personal: ¿qué citas pendientes caen dentro de un bloqueo? ----------
create or replace function public.citas_en_bloqueo(
  p_fecha_ini date, p_fecha_fin date, p_hora_ini time, p_hora_fin time, p_barbero bigint
) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', c.id, 'fecha', c.fecha, 'hora', to_char(c.fecha + c.hora, 'HH24:MI'),
                                             'nombre', c.cliente_nombre, 'telefono', c.telefono) order by c.fecha, c.hora), '[]'::json)
  from citas c
  where public.mi_rol() is not null
    and c.estado = 'agendada' and c.fecha between p_fecha_ini and p_fecha_fin
    and (p_barbero is null or c.barbero_id = p_barbero)
    and (p_hora_ini is null or (public._min(c.hora) < public._min(p_hora_fin)
                                and public._min(c.hora) + c.duracion_min > public._min(p_hora_ini)))
$$;

-- ---------- Permisos ----------
revoke all on function public._bloqueado(bigint,date,int,int) from public, anon, authenticated;
revoke all on function public._cita_cabe(date,time,int,bigint,bigint) from public, anon, authenticated;
revoke all on function public._abierto_hoy() from public, anon, authenticated;
revoke all on function public.dias_cerrados(date,date) from public;
revoke all on function public.cola_publica() from public;
revoke all on function public.agendar_cita_staff(text,text,bigint,bigint,date,time,boolean) from public, anon;
revoke all on function public.mover_cita(bigint,date,time,bigint,boolean) from public, anon;
revoke all on function public.citas_en_bloqueo(date,date,time,time,bigint) from public, anon;
grant execute on function public.dias_cerrados(date,date) to anon, authenticated;
grant execute on function public.cola_publica() to anon, authenticated;
grant execute on function public.agendar_cita_staff(text,text,bigint,bigint,date,time,boolean) to authenticated;
grant execute on function public.mover_cita(bigint,date,time,bigint,boolean) to authenticated;
grant execute on function public.citas_en_bloqueo(date,date,time,time,bigint) to authenticated;
