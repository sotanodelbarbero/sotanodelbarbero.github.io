-- =========================================================
--  Promos en días flojos (Alejandro decide).
--  Pegar todo en Supabase > SQL Editor > Run (después de 17_regreso_lealtad.sql).
--  Se puede volver a ejecutar sin problema.
--
--  - Cada mañana (9:00) se revisan las últimas 8 semanas de cortes cobrados.
--    Si algún día de la semana viene bastante menos gente que el promedio,
--    y ese día cae en los próximos 7 días, se arma una PROPUESTA de promo
--    (en la franja más floja: mañana o tarde) y se le avisa a Alejandro.
--  - Alejandro la acepta, la cambia o la rechaza en el panel (Inicio).
--  - Solo las promos ACEPTADAS se ven en la página de los clientes.
-- =========================================================

create table if not exists public.promos (
  id           bigint generated always as identity primary key,
  fecha        date not null,
  hora_ini     time,                         -- null = todo el día
  hora_fin     time,
  tipo         text not null default 'porcentaje' check (tipo in ('porcentaje', 'monto')),
  valor        numeric(10,2) not null default 15 check (valor > 0),
  texto        text not null default 'en todos los cortes' check (char_length(texto) between 2 and 80),
  motivo       text check (motivo is null or char_length(motivo) <= 160),   -- por qué se propuso
  estado       text not null default 'propuesta' check (estado in ('propuesta', 'aceptada', 'rechazada')),
  origen       text not null default 'sistema' check (origen in ('sistema', 'manual')),
  creado_en    timestamptz not null default now(),
  decidido_en  timestamptz,
  check (hora_ini is null or hora_fin is null or hora_fin > hora_ini),
  check (tipo <> 'porcentaje' or valor <= 100)
);
create unique index if not exists promos_una_por_dia on public.promos (fecha) where estado <> 'rechazada';
alter table public.promos enable row level security;
drop policy if exists promos_staff_leer on public.promos;
drop policy if exists promos_admin on public.promos;
create policy promos_staff_leer on public.promos for select to authenticated using ((select public.mi_rol()) is not null);
create policy promos_admin on public.promos for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

do $$ begin
  alter publication supabase_realtime add table public.promos;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- Promos aceptadas de hoy a 2 semanas (lo único que ven los clientes)
create or replace function public.promos_publicas() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'fecha', fecha, 'hora_ini', to_char(hora_ini, 'HH24:MI'), 'hora_fin', to_char(hora_fin, 'HH24:MI'),
           'tipo', tipo, 'valor', valor, 'texto', texto) order by fecha), '[]'::json)
    from promos
   where estado = 'aceptada' and fecha between public.hoy_local() and public.hoy_local() + 14
$$;
revoke all on function public.promos_publicas() from public;
grant execute on function public.promos_publicas() to anon, authenticated;

-- ---------- Buscar días flojos y proponer promos ----------
-- Devuelve cuántas propuestas nuevas hizo. Necesita al menos 4 semanas con 30+ cortes de historia.
create or replace function public._proponer_promos() returns int
language plpgsql security definer set search_path = public as $$
declare
  hoy      date := public.hoy_local();
  prom     numeric;
  total    int;
  r        record;
  v_f      date;
  h        record;
  e        record;
  abre     time; cierra time;
  nuevas   int := 0;
  ids      bigint[] := '{}';
  v_id     bigint;
  v_url    text; v_sec text;
  dias_txt text[] := array['domingos','lunes','martes','miércoles','jueves','viernes','sábados'];
begin
  -- Cortes por día abierto en las últimas 8 semanas
  create temp table if not exists _conteo (f date, dow int, n int, man int, tar int) on commit drop;
  delete from _conteo;
  insert into _conteo
  select d::date, extract(dow from d)::int,
         (select count(*) from visitas v where v.fecha = d::date and v.estado = 'cobrado'),
         (select count(*) from visitas v where v.fecha = d::date and v.estado = 'cobrado'
                   and extract(hour from v.creado_en at time zone 'America/Mexico_City') < 14),
         (select count(*) from visitas v where v.fecha = d::date and v.estado = 'cobrado'
                   and extract(hour from v.creado_en at time zone 'America/Mexico_City') >= 14)
    from generate_series(hoy - 56, hoy - 1, interval '1 day') d
   where coalesce((select x.abierto from horario_especial x where x.fecha = d::date),
                  (select y.abierto from horario y where y.dia = extract(dow from d)::int), false);

  select avg(n), sum(n) into prom, total from _conteo;
  if coalesce(total, 0) < 30 or (select count(distinct f) from _conteo) < 20 then return 0; end if;

  -- Días de la semana con 30 % o menos de gente que el promedio (mínimo 3 días medidos)
  for r in
    select dow, avg(n) as p, avg(man) as pm, avg(tar) as pt, count(*) as dias
      from _conteo group by dow
     having count(*) >= 3 and avg(n) <= prom * 0.7
     order by avg(n)
  loop
    -- La próxima fecha de ese día dentro de 7 días (desde mañana)
    v_f := hoy + 1 + ((r.dow - extract(dow from hoy + 1)::int + 7) % 7);
    if v_f > hoy + 7 then continue; end if;
    if exists (select 1 from promos where fecha = v_f) then continue; end if;   -- ya hay (aunque se haya rechazado)
    select * into e from horario_especial where fecha = v_f;
    select * into h from horario where dia = r.dow;
    if e.fecha is not null then
      if not e.abierto then continue; end if;
      abre := e.abre; cierra := e.cierra;
    else
      if h.dia is null or not h.abierto then continue; end if;
      abre := h.abre; cierra := h.cierra;
    end if;
    -- La franja más floja: mañana (antes de las 14:00) o tarde
    insert into promos (fecha, hora_ini, hora_fin, motivo)
    values (v_f,
            case when abre >= '14:00' or cierra <= '14:00' then null when r.pm <= r.pt then abre else '14:00' end,
            case when abre >= '14:00' or cierra <= '14:00' then null when r.pm <= r.pt then '14:00' else cierra end,
            format('Los %s vienen %s%% menos clientes que el promedio (%s contra %s al día).',
                   dias_txt[r.dow + 1], round((1 - r.p / prom) * 100), round(r.p, 1), round(prom, 1)))
    returning id into v_id;
    ids := ids || v_id; nuevas := nuevas + 1;
    exit when nuevas >= 2;   -- máximo 2 propuestas a la vez
  end loop;

  -- Aviso a Alejandro (notificación a su celular)
  if nuevas > 0 then
    begin
      select valor into v_url from privado.ajustes where clave = 'avisos_url';
      select valor into v_sec from privado.ajustes where clave = 'avisos_secreto';
      if v_url is not null and v_sec is not null then
        perform net.http_post(url := v_url,
          body := jsonb_build_object('tipo', 'promo', 'promos', to_jsonb(ids)),
          headers := jsonb_build_object('Content-Type', 'application/json', 'x-avisos-secreto', v_sec));
      end if;
    exception when others then null;
    end;
  end if;
  return nuevas;
end $$;
revoke all on function public._proponer_promos() from public, anon, authenticated;

-- Alejandro también puede pedir la revisión desde el panel
create or replace function public.proponer_promos() returns int
language plpgsql security definer set search_path = public as $$
begin
  if public.mi_rol() is distinct from 'admin' then raise exception 'Solo el administrador'; end if;
  return public._proponer_promos();
end $$;
revoke all on function public.proponer_promos() from public, anon;
grant execute on function public.proponer_promos() to authenticated;

-- Todos los días a las 9:00 a. m. (hora de la Ciudad de México = 15:00 UTC)
do $$ begin
  perform cron.schedule('proponer-promos', '0 15 * * *', 'select public._proponer_promos()');
exception when others then
  raise notice 'No se pudo programar la revisión de promos: %', sqlerrm;
end $$;
