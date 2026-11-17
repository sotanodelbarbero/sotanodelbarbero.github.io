-- =========================================================
--  Herramientas de administración: comisiones, gastos,
--  cierre de caja y resumen de clientes.
--  Pegar todo en Supabase > SQL Editor > Run (después de 03_roles.sql).
-- =========================================================

-- ---------- Comisión de cada barbero (% de lo que cobra en servicios) ----------
alter table public.barberos
  add column if not exists comision_pct numeric(5,2) not null default 50
  check (comision_pct between 0 and 100);

-- ---------- Gastos / salidas de efectivo de la caja ----------
create table if not exists public.gastos (
  id          bigint generated always as identity primary key,
  fecha       date not null default public.hoy_local(),
  concepto    text not null check (char_length(btrim(concepto)) between 1 and 120),
  monto       numeric(10,2) not null check (monto > 0),
  creado_en   timestamptz not null default now(),
  creado_por  uuid default auth.uid() references auth.users(id)
);
create index if not exists gastos_fecha_idx on public.gastos (fecha);
alter table public.gastos enable row level security;
drop policy if exists gastos_admin on public.gastos;
create policy gastos_admin on public.gastos for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

-- ---------- Cierre de caja por día ----------
create table if not exists public.cortes (
  fecha             date primary key,
  fondo_inicial     numeric(10,2) not null default 0 check (fondo_inicial >= 0),
  efectivo_contado  numeric(10,2) check (efectivo_contado >= 0),
  notas             text check (char_length(notas) <= 500),
  cerrado_en        timestamptz,
  cerrado_por       uuid references auth.users(id)
);
alter table public.cortes enable row level security;
drop policy if exists cortes_admin on public.cortes;
create policy cortes_admin on public.cortes for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

-- Quién cerró y cuándo lo pone la base de datos
create or replace function public._sellar_corte() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.cerrado_en is not null and (tg_op = 'INSERT' or old.cerrado_en is null) then
    new.cerrado_en := now();
    new.cerrado_por := auth.uid();
  end if;
  return new;
end $$;
drop trigger if exists sellar_corte on public.cortes;
create trigger sellar_corte before insert or update on public.cortes
  for each row execute function public._sellar_corte();

-- ---------- Resumen de clientes ----------
-- Agrupa por teléfono (o por nombre si no dejó teléfono).
-- security_invoker: respeta las reglas de seguridad de quien consulta.
create or replace view public.clientes_resumen with (security_invoker = true) as
select
  coalesce(telefono, 'nombre:' || lower(btrim(cliente_nombre)))          as clave,
  (array_agg(cliente_nombre order by creado_en desc))[1]                 as nombre,
  max(telefono)                                                          as telefono,
  count(*) filter (where estado = 'cobrado')                             as visitas,
  coalesce(sum(monto + propina) filter (where estado = 'cobrado'), 0)    as gastado,
  min(fecha)                                                             as primera_visita,
  max(fecha)                                                             as ultima_visita
from public.visitas
where estado <> 'cancelado'
group by 1;

revoke all on public.clientes_resumen from anon;
grant select on public.clientes_resumen to authenticated;
