-- =========================================================
--  Turnos de los barberos: cada uno puede tener su propio horario.
--  Pegar todo en Supabase > SQL Editor > Run (después de 11_llegada.sql).
--  Se puede volver a ejecutar sin problema.
--
--  - Si un barbero NO tiene turno propio (usa_turno = false), trabaja
--    todo el horario de la barbería, como hasta ahora.
--  - Si tiene turno propio, solo trabaja los días y horas de barbero_turno.
--    Ej.: Juan lunes a viernes 10:00–16:00, Pedro martes a sábado 14:00–20:00.
--  - Las citas solo se apartan cuando hay un barbero de turno libre
--    (y con un barbero elegido, solo dentro de su turno).
-- =========================================================

alter table public.barberos add column if not exists usa_turno boolean not null default false;

create table if not exists public.barbero_turno (
  barbero_id bigint not null references public.barberos(id) on delete cascade,
  dia        smallint not null check (dia between 0 and 6),   -- 0 = domingo
  entra      time not null,
  sale       time not null,
  primary key (barbero_id, dia),
  check (sale > entra)
);
alter table public.barbero_turno enable row level security;
drop policy if exists barbero_turno_leer on public.barbero_turno;
drop policy if exists barbero_turno_admin on public.barbero_turno;
create policy barbero_turno_leer on public.barbero_turno for select to authenticated using ((select public.mi_rol()) is not null);
create policy barbero_turno_admin on public.barbero_turno for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

do $$ begin
  alter publication supabase_realtime add table public.barbero_turno;
exception when duplicate_object then null; end $$;

-- ¿El barbero está fuera de su turno en ese rato? (false si no usa turno propio)
create or replace function public._fuera_turno(p_barbero bigint, p_fecha date, p_ini int, p_fin int) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select usa_turno from barberos where id = p_barbero), false)
     and not exists (
       select 1 from barbero_turno t
       where t.barbero_id = p_barbero and t.dia = extract(dow from p_fecha)::int
         and public._min(t.entra) <= p_ini and public._min(t.sale) >= p_fin
     )
$$;

-- ---------- ¿Cabe una cita? Ahora también respeta los turnos ----------
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
    if public._fuera_turno(p_barbero, p_fecha, ini, fin) then return false; end if;
    if exists (
      select 1 from citas c
      where c.fecha = p_fecha and c.barbero_id = p_barbero and c.estado in ('agendada','llego')
        and c.id is distinct from p_excluir
        and public._min(c.hora) < fin and public._min(c.hora) + c.duracion_min > ini
    ) then return false; end if;
  end if;

  -- Cuántos barberos trabajan en ese rato (de turno y sin bloqueo)
  select count(*) into activos from barberos where activo;
  select count(*) into libres from barberos b
   where b.activo and not public._bloqueado(b.id, p_fecha, ini, fin)
     and not public._fuera_turno(b.id, p_fecha, ini, fin);
  if activos = 0 then libres := 1; end if;
  if libres = 0 then return false; end if;

  select count(*) into encimadas from citas c
  where c.fecha = p_fecha and c.estado in ('agendada','llego')
    and c.id is distinct from p_excluir
    and public._min(c.hora) < fin and public._min(c.hora) + c.duracion_min > ini;
  return encimadas < libres;
end $$;

-- ---------- Público: barberos con su turno (para que el cliente sepa cuándo está cada uno) ----------
create or replace function public.barberos_publicos() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'id', b.id, 'nombre', b.nombre,
           'turno', case when b.usa_turno then (
             select coalesce(json_agg(json_build_object('dia', t.dia, 'entra', to_char(t.entra, 'HH24:MI'), 'sale', to_char(t.sale, 'HH24:MI')) order by t.dia), '[]'::json)
             from barbero_turno t where t.barbero_id = b.id) end
         ) order by b.nombre), '[]'::json)
  from barberos b where b.activo
$$;

-- ---------- Admin: guardar el turno de un barbero de una vez ----------
-- p_dias: [{"dia":1,"entra":"10:00","sale":"16:00"}, …]; p_usa = false → vuelve al horario de la barbería
create or replace function public.guardar_turno(p_barbero bigint, p_usa boolean, p_dias json) returns boolean
language plpgsql security definer set search_path = public as $$
declare d json;
begin
  if public.mi_rol() is distinct from 'admin' then raise exception 'Solo el administrador puede cambiar turnos'; end if;
  if not exists (select 1 from barberos where id = p_barbero) then raise exception 'El barbero no existe'; end if;
  if p_usa and json_array_length(coalesce(p_dias, '[]'::json)) = 0 then raise exception 'Marca al menos un día de trabajo'; end if;
  delete from barbero_turno where barbero_id = p_barbero;
  if p_usa then
    for d in select * from json_array_elements(p_dias) loop
      if (d->>'sale')::time <= (d->>'entra')::time then raise exception 'La hora de salida debe ser después de la de entrada'; end if;
      insert into barbero_turno (barbero_id, dia, entra, sale)
      values (p_barbero, (d->>'dia')::smallint, (d->>'entra')::time, (d->>'sale')::time);
    end loop;
  end if;
  update barberos set usa_turno = p_usa where id = p_barbero;
  return true;
end $$;

revoke all on function public._fuera_turno(bigint,date,int,int) from public, anon, authenticated;
revoke all on function public._cita_cabe(date,time,int,bigint,bigint) from public, anon, authenticated;
revoke all on function public.guardar_turno(bigint,boolean,json) from public, anon;
grant execute on function public.guardar_turno(bigint,boolean,json) to authenticated;
grant execute on function public.barberos_publicos() to anon, authenticated;
