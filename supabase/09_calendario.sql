-- =========================================================
--  Calendario de apertura: horario distinto en días específicos.
--  Pegar todo en Supabase > SQL Editor > Run (después de 08_panel.sql).
--  Se puede volver a ejecutar sin problema.
--
--  - "horario" sigue siendo el horario normal de cada día de la semana.
--  - "horario_especial" cambia un día concreto: cerrar el 24 de diciembre,
--    abrir un domingo, o abrir el sábado 13 de 9:00 a 15:00.
--  - Todas las reglas (citas, turnos, "abierto ahora") usan el horario
--    del día: el especial si existe, si no el normal.
-- =========================================================

create table if not exists public.horario_especial (
  fecha    date primary key,
  abierto  boolean not null,
  abre     time,
  cierra   time,
  nota     text check (nota is null or char_length(nota) <= 60),
  check (not abierto or (abre is not null and cierra is not null and cierra > abre))
);
alter table public.horario_especial enable row level security;
drop policy if exists horario_especial_leer on public.horario_especial;
drop policy if exists horario_especial_admin on public.horario_especial;
create policy horario_especial_leer on public.horario_especial for select to anon, authenticated using (true);
create policy horario_especial_admin on public.horario_especial for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

do $$ begin
  alter publication supabase_realtime add table public.horario_especial;
exception when duplicate_object then null; end $$;

-- Horario que aplica en una fecha (especial si hay, si no el de la semana)
create or replace function public._horario_dia(p_fecha date) returns horario
language plpgsql stable security definer set search_path = public as $$
declare
  h  horario;
  e  horario_especial;
begin
  select * into h from horario where dia = extract(dow from p_fecha)::int;
  select * into e from horario_especial where fecha = p_fecha;
  if found then
    h.dia := extract(dow from p_fecha)::int;
    h.abierto := e.abierto;
    if e.abierto then h.abre := e.abre; h.cierra := e.cierra; end if;
  end if;
  return h;   -- campos vacíos si no hay horario para ese día
end $$;

-- ---------- Público: el mes para el calendario del cliente ----------
-- Por día: abierto, abre, cierra y si cambió respecto al horario normal.
create or replace function public.calendario_publico(p_desde date, p_hasta date) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'fecha',   d.f,
           'abierto', coalesce(h.abierto, false) and not exists (
                        select 1 from bloqueos b where b.barbero_id is null and b.hora_ini is null
                          and d.f between b.fecha_ini and b.fecha_fin),
           'abre',    to_char(d.f + h.abre, 'HH24:MI'),
           'cierra',  to_char(d.f + h.cierra, 'HH24:MI'),
           'especial', exists (select 1 from horario_especial e where e.fecha = d.f)
         ) order by d.f), '[]'::json)
  from (select g::date as f from generate_series(p_desde, least(p_hasta, p_desde + 62), interval '1 day') g) d
  cross join lateral (select * from public._horario_dia(d.f)) h
$$;

-- =========================================================
--  Las reglas de antes, ahora con el horario del día
-- =========================================================

create or replace function public._cita_cabe(
  p_fecha date, p_hora time, p_dur int, p_barbero bigint, p_excluir bigint default null
) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  h    horario := public._horario_dia(p_fecha);
  ini  int := public._min(p_hora);
  fin  int := public._min(p_hora) + p_dur;
  activos int;
  libres  int;
  encimadas int;
begin
  if p_fecha < hoy_local() or p_fecha > hoy_local() + 30 then return false; end if;
  if (p_fecha + p_hora) < ahora_local() + interval '15 minutes' then return false; end if;
  if h.abierto is not true then return false; end if;
  if ini < public._min(h.abre) or fin > public._min(h.cierra) then return false; end if;

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

create or replace function public.horarios_disponibles(
  p_fecha date, p_servicio_id bigint, p_barbero_id bigint default null
) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  h   horario := public._horario_dia(p_fecha);
  dur int;
begin
  select duracion_min into dur from servicios where id = p_servicio_id and activo;
  if dur is null or h.abierto is not true then return '[]'::json; end if;
  return coalesce((
    select json_agg(to_char(g.ts, 'HH24:MI') order by g.ts)
    from generate_series(p_fecha + h.abre, p_fecha + h.cierra - make_interval(mins => dur), interval '30 minutes') g(ts)
    where public._cita_cabe(p_fecha, g.ts::time, dur, p_barbero_id)
  ), '[]'::json);
end $$;

create or replace function public._abierto_hoy() returns json
language plpgsql stable security definer set search_path = public as $$
declare
  ahora  timestamp := ahora_local();
  h      horario := public._horario_dia(ahora_local()::date);
  t      int := public._min(ahora_local()::time);
  bl     bloqueos;
  d      int;
  f      date;
  sig    horario;
  sig_f  date;
  sig_h  time;
begin
  select * into bl from bloqueos b
   where b.barbero_id is null and ahora::date between b.fecha_ini and b.fecha_fin
     and (b.hora_ini is null or (t >= public._min(b.hora_ini) and t < public._min(b.hora_fin)))
   order by b.hora_ini nulls first limit 1;

  for d in 0..45 loop
    f := ahora::date + d;
    sig := public._horario_dia(f);
    continue when sig.abierto is not true;
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

create or replace function public.cola_publica() returns json
language plpgsql stable security definer set search_path = public as $$
declare
  est     json := public._abierto_hoy();
  v_min   int  := public._espera(hoy_local(), null);
  v_cierra time := (public._horario_dia(hoy_local())).cierra;
begin
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

create or replace function public.registrar_turno(
  p_nombre text, p_telefono text, p_servicio_id bigint
) returns json
language plpgsql security definer set search_path = public as $$
declare
  tel   text := nullif(regexp_replace(coalesce(p_telefono, ''), '[^0-9+]', '', 'g'), '');
  ya    visitas;
  est   json;
  h     horario := public._horario_dia(hoy_local());
  dur   int;
  v_turno int;
  v_token uuid;
begin
  if tel is not null then
    select * into ya from visitas
     where fecha = hoy_local() and telefono = left(tel, 20) and estado in ('espera','atendiendo')
     order by turno desc limit 1;
    if found then return json_build_object('turno', ya.turno, 'token', ya.token, 'repetido', true); end if;
  end if;

  est := public._abierto_hoy();
  if not (est->>'abierto')::boolean then raise exception 'Cerrado'; end if;
  select coalesce(duracion_min, 30) into dur from servicios where id = p_servicio_id and activo;
  if ahora_local()::time + make_interval(mins => public._espera(hoy_local(), null) + coalesce(dur, 30)) > h.cierra then
    raise exception 'Ya no alcanza el tiempo hoy';
  end if;

  v_turno := public.registrar_visita(p_nombre, p_telefono, p_servicio_id);
  select token into v_token from visitas where fecha = hoy_local() and turno = v_turno;
  return json_build_object('turno', v_turno, 'token', v_token);
end $$;

-- ---------- Permisos ----------
revoke all on function public._horario_dia(date) from public, anon, authenticated;
revoke all on function public._cita_cabe(date,time,int,bigint,bigint) from public, anon, authenticated;
revoke all on function public._abierto_hoy() from public, anon, authenticated;
revoke all on function public.calendario_publico(date,date) from public;
revoke all on function public.horarios_disponibles(date,bigint,bigint) from public;
revoke all on function public.cola_publica() from public;
revoke all on function public.registrar_turno(text,text,bigint) from public;
grant execute on function public.calendario_publico(date,date) to anon, authenticated;
grant execute on function public.horarios_disponibles(date,bigint,bigint) to anon, authenticated;
grant execute on function public.cola_publica() to anon, authenticated;
grant execute on function public.registrar_turno(text,text,bigint) to anon, authenticated;
