-- =========================================================
--  Roles: admin (Alejandro), barbero, cliente (QR, sin cuenta)
--  1) Cambia CORREO-DE-ALEJANDRO (al final) por el correo de su cuenta.
--  2) Pega todo en Supabase > SQL Editor > Run.
--  Reemplaza al PIN de 02_precios_con_pin.sql (se elimina aquí).
-- =========================================================

-- ---------- Perfiles del personal ----------
-- Cada cuenta de Authentication tiene un perfil. rol = null significa
-- "pendiente": la cuenta existe pero Alejandro aún no la aprueba.
create table if not exists public.perfiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  email       text,
  rol         text check (rol in ('admin','barbero')),
  barbero_id  bigint references public.barberos(id) on delete set null,
  creado_en   timestamptz not null default now()
);
alter table public.perfiles enable row level security;

-- Funciones que usan las reglas de seguridad
create or replace function public.mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select rol from perfiles where user_id = auth.uid()
$$;
create or replace function public.mi_barbero() returns bigint
language sql stable security definer set search_path = public as $$
  select barbero_id from perfiles where user_id = auth.uid()
$$;
revoke all on function public.mi_rol() from public, anon;
revoke all on function public.mi_barbero() from public, anon;
grant execute on function public.mi_rol() to authenticated;
grant execute on function public.mi_barbero() to authenticated;

-- Al crear una cuenta en Authentication se crea su perfil (pendiente)
create or replace function public._nuevo_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfiles (user_id, email) values (new.id, new.email)
  on conflict (user_id) do nothing;
  return new;
end $$;
drop trigger if exists crear_perfil on auth.users;
create trigger crear_perfil after insert on auth.users
  for each row execute function public._nuevo_perfil();

-- Perfiles para las cuentas que ya existían
insert into public.perfiles (user_id, email)
select id, email from auth.users
on conflict (user_id) do nothing;

-- Que nunca se quede el negocio sin administrador
create or replace function public._proteger_admin() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.rol = 'admin' and new.rol is distinct from 'admin'
     and not exists (select 1 from perfiles where rol = 'admin' and user_id <> old.user_id) then
    raise exception 'Debe quedar al menos un administrador';
  end if;
  return new;
end $$;
drop trigger if exists proteger_admin on public.perfiles;
create trigger proteger_admin before update on public.perfiles
  for each row execute function public._proteger_admin();

-- ---------- Reglas de seguridad (RLS) ----------
-- Perfiles: cada quien ve el suyo; el admin ve y edita todos.
drop policy if exists perfiles_leer on public.perfiles;
drop policy if exists perfiles_admin on public.perfiles;
create policy perfiles_leer on public.perfiles for select to authenticated
  using (user_id = auth.uid() or (select public.mi_rol()) = 'admin');
create policy perfiles_admin on public.perfiles for update to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

-- Servicios: el personal los lee; solo el admin los cambia.
-- (El cliente sin cuenta los lee con la política servicios_publicos de schema.sql.)
drop policy if exists servicios_staff on public.servicios;
drop policy if exists servicios_staff_lectura on public.servicios;
drop policy if exists servicios_leer on public.servicios;
drop policy if exists servicios_admin on public.servicios;
create policy servicios_leer on public.servicios for select to authenticated
  using ((select public.mi_rol()) is not null);
create policy servicios_admin on public.servicios for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

-- Barberos: el personal los lee; solo el admin los cambia.
drop policy if exists barberos_staff on public.barberos;
drop policy if exists barberos_leer on public.barberos;
drop policy if exists barberos_admin on public.barberos;
create policy barberos_leer on public.barberos for select to authenticated
  using ((select public.mi_rol()) is not null);
create policy barberos_admin on public.barberos for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

-- Visitas
drop policy if exists visitas_staff on public.visitas;
drop policy if exists visitas_admin on public.visitas;
drop policy if exists visitas_barbero_leer on public.visitas;
drop policy if exists visitas_barbero_editar on public.visitas;
-- Admin: todo.
create policy visitas_admin on public.visitas for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');
-- Barbero: ve la cola de hoy y su propio historial.
create policy visitas_barbero_leer on public.visitas for select to authenticated
  using ((select public.mi_rol()) = 'barbero'
         and (fecha = public.hoy_local() or barbero_id = (select public.mi_barbero())));
-- Barbero: solo puede mover turnos de HOY que aún no están cobrados
-- (atender, cobrar, cancelar, reabrir). Un cobro hecho solo lo corrige el admin.
create policy visitas_barbero_editar on public.visitas for update to authenticated
  using ((select public.mi_rol()) = 'barbero' and fecha = public.hoy_local()
         and estado in ('espera','atendiendo','cancelado'))
  with check ((select public.mi_rol()) = 'barbero' and fecha = public.hoy_local());

-- Quién y cuándo cobró lo pone la base de datos (no se puede falsificar)
create or replace function public._sellar_cobro() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.estado = 'cobrado' and old.estado is distinct from 'cobrado' then
    new.cobrado_por := auth.uid();
    new.cobrado_en  := now();
  end if;
  if public.mi_rol() is distinct from 'admin' then
    -- un barbero no puede cambiar datos del registro original
    new.fecha := old.fecha; new.turno := old.turno; new.creado_en := old.creado_en;
  end if;
  return new;
end $$;
drop trigger if exists sellar_cobro on public.visitas;
create trigger sellar_cobro before update on public.visitas
  for each row execute function public._sellar_cobro();

-- ---------- Quitar el PIN (ya no hace falta) ----------
drop function if exists public.guardar_servicio(text,bigint,text,numeric,boolean);
drop function if exists public.cambiar_pin(text,text);
drop function if exists public.verificar_pin(text);
drop function if exists public._revisar_pin(text);
drop table if exists public.config_privada;

-- ---------- Primer administrador ----------
update public.perfiles set rol = 'admin'
where lower(email) = lower('CORREO-DE-ALEJANDRO');

-- Revisa el resultado: debe aparecer Alejandro con rol admin
select email, rol from public.perfiles order by rol nulls last, email;
