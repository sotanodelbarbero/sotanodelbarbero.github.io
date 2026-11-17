-- =========================================================
--  Productos (pomadas, ceras, aceites…): venta e inventario.
--  Pegar todo en Supabase > SQL Editor > Run (después de 05_cliente.sql).
--
--  - Cada venta descuenta existencias automáticamente (y las regresa si
--    se borra la venta).
--  - Los productos NO generan comisión para el barbero: son del negocio.
-- =========================================================

-- ---------- Catálogo de productos ----------
create table if not exists public.productos (
  id           bigint generated always as identity primary key,
  nombre       text not null check (char_length(btrim(nombre)) between 1 and 80),
  precio       numeric(10,2) not null default 0 check (precio >= 0),
  costo        numeric(10,2) not null default 0 check (costo >= 0),  -- lo que le cuesta al negocio
  existencias  int not null default 0,                               -- puede quedar negativo si se vende sin registrar la entrada
  minimo       int not null default 2 check (minimo >= 0),           -- avisa cuando quedan esto o menos
  activo       boolean not null default true,
  creado_en    timestamptz not null default now()
);
alter table public.productos enable row level security;

drop policy if exists productos_leer on public.productos;
drop policy if exists productos_admin on public.productos;
create policy productos_leer on public.productos for select to authenticated
  using ((select public.mi_rol()) is not null);
create policy productos_admin on public.productos for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

-- ---------- Ventas de productos ----------
-- visita_id: si se vendió junto con un corte. Vacío = venta sin corte (mostrador).
create table if not exists public.ventas_productos (
  id              bigint generated always as identity primary key,
  fecha           date not null default public.hoy_local(),
  visita_id       bigint references public.visitas(id) on delete cascade,
  producto_id     bigint not null references public.productos(id),
  cantidad        int not null check (cantidad between 1 and 999),
  precio_unit     numeric(10,2) not null check (precio_unit >= 0),
  costo_unit      numeric(10,2) not null default 0,
  metodo_pago     text not null check (metodo_pago in ('efectivo','tarjeta','transferencia')),
  barbero_id      bigint references public.barberos(id) on delete set null,
  cliente_nombre  text check (cliente_nombre is null or char_length(cliente_nombre) <= 80),
  creado_en       timestamptz not null default now(),
  creado_por      uuid references auth.users(id)
);
create index if not exists ventas_productos_fecha_idx on public.ventas_productos (fecha);
create index if not exists ventas_productos_visita_idx on public.ventas_productos (visita_id);
alter table public.ventas_productos enable row level security;

drop policy if exists ventas_productos_admin on public.ventas_productos;
drop policy if exists ventas_productos_barbero_leer on public.ventas_productos;
drop policy if exists ventas_productos_barbero_vender on public.ventas_productos;
-- Admin: todo (incluye borrar una venta equivocada).
create policy ventas_productos_admin on public.ventas_productos for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');
-- Barbero: ve lo de hoy y su propio historial.
create policy ventas_productos_barbero_leer on public.ventas_productos for select to authenticated
  using ((select public.mi_rol()) = 'barbero'
         and (fecha = public.hoy_local() or barbero_id = (select public.mi_barbero())));
-- Barbero: solo puede registrar ventas de HOY (no borrar ni cambiar).
create policy ventas_productos_barbero_vender on public.ventas_productos for insert to authenticated
  with check ((select public.mi_rol()) = 'barbero' and fecha = public.hoy_local());

-- Datos que pone la base de datos (no se pueden falsificar desde el panel)
create or replace function public._preparar_venta_producto() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select costo into new.costo_unit from productos where id = new.producto_id;
  new.costo_unit := coalesce(new.costo_unit, 0);
  if tg_op = 'INSERT' then
    new.creado_por := auth.uid();
    new.creado_en  := now();
  end if;
  -- La venta va en el mismo día que el corte al que pertenece
  if new.visita_id is not null then
    select fecha into new.fecha from visitas where id = new.visita_id;
  end if;
  return new;
end $$;
drop trigger if exists preparar_venta_producto on public.ventas_productos;
create trigger preparar_venta_producto before insert or update on public.ventas_productos
  for each row execute function public._preparar_venta_producto();

-- Inventario: vender descuenta, borrar la venta regresa la mercancía
create or replace function public._mover_existencias() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('UPDATE','DELETE') then
    update productos set existencias = existencias + old.cantidad where id = old.producto_id;
  end if;
  if tg_op in ('INSERT','UPDATE') then
    update productos set existencias = existencias - new.cantidad where id = new.producto_id;
  end if;
  return null;
end $$;
drop trigger if exists mover_existencias on public.ventas_productos;
create trigger mover_existencias after insert or update or delete on public.ventas_productos
  for each row execute function public._mover_existencias();

revoke all on function public._preparar_venta_producto() from public, anon, authenticated;
revoke all on function public._mover_existencias() from public, anon, authenticated;

-- ---------- Entrada de mercancía (solo admin) ----------
create or replace function public.sumar_existencias(p_id bigint, p_cantidad int) returns int
language plpgsql security invoker set search_path = public as $$
declare v_total int;
begin
  if public.mi_rol() is distinct from 'admin' then
    raise exception 'Solo el administrador puede registrar entradas';
  end if;
  if p_cantidad is null or p_cantidad = 0 or abs(p_cantidad) > 10000 then
    raise exception 'Cantidad inválida';
  end if;
  update productos set existencias = existencias + p_cantidad where id = p_id
  returning existencias into v_total;
  return v_total;
end $$;
revoke all on function public.sumar_existencias(bigint,int) from public, anon;
grant execute on function public.sumar_existencias(bigint,int) to authenticated;

-- Actualización en vivo del panel
do $$ begin
  alter publication supabase_realtime add table public.ventas_productos;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.productos;
exception when duplicate_object then null; end $$;

-- ---------- Productos de ejemplo (editar desde el panel después) ----------
insert into public.productos (nombre, precio, costo, existencias)
select * from (values
  ('Pomada', 180, 90, 0),
  ('Cera mate', 200, 100, 0),
  ('Aceite para barba', 220, 110, 0)
) v(nombre, precio, costo, existencias)
where not exists (select 1 from public.productos);
