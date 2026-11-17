-- =========================================================
--  Barbería — esquema de base de datos (Supabase / Postgres)
--  Pegar completo en: Supabase > SQL Editor > New query > Run
-- =========================================================

-- Zona horaria del negocio: el "día" de cada visita se calcula aquí.
-- Cambiar si la barbería no está en hora del centro de México.
create or replace function public.hoy_local() returns date
language sql stable as $$
  select (now() at time zone 'America/Mexico_City')::date
$$;

-- ---------- Catálogos ----------
create table if not exists public.servicios (
  id      bigint generated always as identity primary key,
  nombre  text not null,
  precio  numeric(10,2) not null default 0,
  activo  boolean not null default true,
  orden   int not null default 0
);

create table if not exists public.barberos (
  id      bigint generated always as identity primary key,
  nombre  text not null,
  activo  boolean not null default true
);

-- ---------- Visitas (un registro por cliente que llega) ----------
create table if not exists public.visitas (
  id              bigint generated always as identity primary key,
  fecha           date not null default public.hoy_local(),
  turno           int  not null,
  creado_en       timestamptz not null default now(),
  cliente_nombre  text not null check (char_length(cliente_nombre) between 1 and 80),
  telefono        text check (telefono is null or char_length(telefono) <= 20),
  servicio_id     bigint references public.servicios(id),
  barbero_id      bigint references public.barberos(id),
  estado          text not null default 'espera'
                  check (estado in ('espera','atendiendo','cobrado','cancelado')),
  monto           numeric(10,2),
  propina         numeric(10,2) not null default 0,
  metodo_pago     text check (metodo_pago in ('efectivo','tarjeta','transferencia')),
  cobrado_en      timestamptz,
  cobrado_por     uuid references auth.users(id),
  unique (fecha, turno)
);

create index if not exists visitas_fecha_idx on public.visitas (fecha);

-- ---------- Registro público (lo que usa el QR) ----------
-- Los clientes NO tienen acceso directo a la tabla; solo pueden llamar
-- esta función, que valida, asigna turno del día y devuelve el número.
create or replace function public.registrar_visita(
  p_nombre text, p_telefono text, p_servicio_id bigint
) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_turno int;
  v_hoy   date := public.hoy_local();
begin
  p_nombre := btrim(p_nombre);
  p_telefono := nullif(regexp_replace(coalesce(p_telefono,''), '[^0-9+]', '', 'g'), '');
  if p_nombre is null or char_length(p_nombre) < 2 or char_length(p_nombre) > 80 then
    raise exception 'Nombre inválido';
  end if;
  if not exists (select 1 from servicios where id = p_servicio_id and activo) then
    raise exception 'Servicio inválido';
  end if;

  -- Bloquea por día para que dos registros simultáneos no reciban el mismo turno
  perform pg_advisory_xact_lock(hashtext('turno-' || v_hoy::text));
  select coalesce(max(turno), 0) + 1 into v_turno from visitas where fecha = v_hoy;

  insert into visitas (fecha, turno, cliente_nombre, telefono, servicio_id)
  values (v_hoy, v_turno, p_nombre, left(p_telefono, 20), p_servicio_id);
  return v_turno;
end $$;

revoke all on function public.registrar_visita(text,text,bigint) from public;
grant execute on function public.registrar_visita(text,text,bigint) to anon, authenticated;

-- ---------- Seguridad (RLS) ----------
alter table public.servicios enable row level security;
alter table public.barberos  enable row level security;
alter table public.visitas   enable row level security;

-- Clientes (anon): solo pueden ver la lista de servicios activos.
drop policy if exists servicios_publicos on public.servicios;
create policy servicios_publicos on public.servicios
  for select to anon using (activo);

-- Las reglas para el personal (admin y barberos) están en 03_roles.sql.

-- Actualización en vivo del panel cuando llega un cliente nuevo
do $$ begin
  alter publication supabase_realtime add table public.visitas;
exception when duplicate_object then null; end $$;

-- ---------- Datos de ejemplo (editar desde el panel después) ----------
insert into public.servicios (nombre, precio, orden)
select * from (values
  ('Corte', 150, 1),
  ('Corte + barba', 220, 2),
  ('Barba', 100, 3),
  ('Corte niño', 120, 4),
  ('Diseño / línea', 50, 5)
) v(nombre, precio, orden)
where not exists (select 1 from public.servicios);
