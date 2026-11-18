-- =========================================================
--  Quién trabaja en un día específico (los horarios varían).
--  Pegar todo en Supabase > SQL Editor > Run (después de 12_turnos.sql).
--  Se puede volver a ejecutar sin problema.
--
--  Al darle horario a un día en el calendario, Alejandro dice quién
--  trabaja ese día y de qué hora a qué hora. Eso manda sobre el turno
--  de la semana solo en esa fecha.
--  - trabaja = false → ese barbero no viene ese día.
--  - Sin fila para la fecha → se usa su turno de la semana (12_turnos.sql).
-- =========================================================

create table if not exists public.barbero_turno_dia (
  barbero_id bigint not null references public.barberos(id) on delete cascade,
  fecha      date not null,
  trabaja    boolean not null,
  entra      time,
  sale       time,
  primary key (barbero_id, fecha),
  check (not trabaja or (entra is not null and sale is not null and sale > entra))
);
create index if not exists barbero_turno_dia_fecha on public.barbero_turno_dia (fecha);
alter table public.barbero_turno_dia enable row level security;
drop policy if exists barbero_turno_dia_leer on public.barbero_turno_dia;
drop policy if exists barbero_turno_dia_admin on public.barbero_turno_dia;
create policy barbero_turno_dia_leer on public.barbero_turno_dia for select to authenticated using ((select public.mi_rol()) is not null);
create policy barbero_turno_dia_admin on public.barbero_turno_dia for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

do $$ begin
  alter publication supabase_realtime add table public.barbero_turno_dia;
exception when duplicate_object then null; end $$;

-- ¿El barbero está fuera de turno en ese rato? Primero el día específico, si no, el turno de la semana
create or replace function public._fuera_turno(p_barbero bigint, p_fecha date, p_ini int, p_fin int) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from barbero_turno_dia x where x.barbero_id = p_barbero and x.fecha = p_fecha) then
      not exists (select 1 from barbero_turno_dia x
                  where x.barbero_id = p_barbero and x.fecha = p_fecha and x.trabaja
                    and public._min(x.entra) <= p_ini and public._min(x.sale) >= p_fin)
    else
      coalesce((select usa_turno from barberos where id = p_barbero), false)
      and not exists (
        select 1 from barbero_turno t
        where t.barbero_id = p_barbero and t.dia = extract(dow from p_fecha)::int
          and public._min(t.entra) <= p_ini and public._min(t.sale) >= p_fin)
  end
$$;

-- ---------- Admin: quién trabaja en unas fechas ----------
-- p_turnos: [{"barbero_id":1,"trabaja":true,"entra":"10:00","sale":"15:00"}, {"barbero_id":2,"trabaja":false}]
-- p_turnos null → esas fechas vuelven al turno de la semana
create or replace function public.guardar_turno_dias(p_fechas date[], p_turnos json) returns boolean
language plpgsql security definer set search_path = public as $$
declare d json; f date;
begin
  if public.mi_rol() is distinct from 'admin' then raise exception 'Solo el administrador puede cambiar turnos'; end if;
  if coalesce(array_length(p_fechas, 1), 0) = 0 or array_length(p_fechas, 1) > 62 then raise exception 'Elige de 1 a 62 días'; end if;
  delete from barbero_turno_dia where fecha = any(p_fechas);
  if p_turnos is null then return true; end if;
  for d in select * from json_array_elements(p_turnos) loop
    if (d->>'trabaja')::boolean and (d->>'sale')::time <= (d->>'entra')::time then
      raise exception 'La hora de salida debe ser después de la de entrada';
    end if;
    foreach f in array p_fechas loop
      insert into barbero_turno_dia (barbero_id, fecha, trabaja, entra, sale)
      values ((d->>'barbero_id')::bigint, f, (d->>'trabaja')::boolean,
              case when (d->>'trabaja')::boolean then (d->>'entra')::time end,
              case when (d->>'trabaja')::boolean then (d->>'sale')::time end);
    end loop;
  end loop;
  return true;
end $$;

revoke all on function public._fuera_turno(bigint,date,int,int) from public, anon, authenticated;
revoke all on function public.guardar_turno_dias(date[],json) from public, anon;
grant execute on function public.guardar_turno_dias(date[],json) to authenticated;
