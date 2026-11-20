-- =========================================================
--  Fotos de cortes por barbero.
--  Pegar todo en Supabase > SQL Editor > Run (después de 18_promos.sql).
--  Se puede volver a ejecutar sin problema.
--
--  - Cada barbero sube fotos de SUS cortes desde el panel (pestaña Fotos).
--    Alejandro (admin) puede subir, ocultar o borrar las de cualquiera.
--  - Las fotos se guardan en Supabase Storage, en la carpeta pública «cortes»
--    (cortes/<id del barbero>/<archivo>.jpg).
--  - Los clientes ven las fotos visibles en la página principal y al agendar.
-- =========================================================

create table if not exists public.fotos_cortes (
  id           bigint generated always as identity primary key,
  barbero_id   bigint not null references public.barberos(id) on delete cascade,
  ruta         text not null unique check (char_length(ruta) between 3 and 200),   -- ruta dentro de la carpeta «cortes»
  descripcion  text check (descripcion is null or char_length(descripcion) <= 60),   -- ej. «Taper fade»
  visible      boolean not null default true,
  creado_en    timestamptz not null default now()
);
create index if not exists fotos_cortes_barbero on public.fotos_cortes (barbero_id, creado_en desc);
alter table public.fotos_cortes enable row level security;
drop policy if exists fotos_staff_leer on public.fotos_cortes;
drop policy if exists fotos_subir on public.fotos_cortes;
drop policy if exists fotos_cambiar on public.fotos_cortes;
drop policy if exists fotos_borrar on public.fotos_cortes;
-- Todo el equipo ve todas; cada barbero solo sube, cambia o borra las suyas (el admin, todas)
create policy fotos_staff_leer on public.fotos_cortes for select to authenticated using ((select public.mi_rol()) is not null);
create policy fotos_subir on public.fotos_cortes for insert to authenticated
  with check ((select public.mi_rol()) = 'admin' or barbero_id = (select public.mi_barbero()));
create policy fotos_cambiar on public.fotos_cortes for update to authenticated
  using ((select public.mi_rol()) = 'admin' or barbero_id = (select public.mi_barbero()))
  with check ((select public.mi_rol()) = 'admin' or barbero_id = (select public.mi_barbero()));
create policy fotos_borrar on public.fotos_cortes for delete to authenticated
  using ((select public.mi_rol()) = 'admin' or barbero_id = (select public.mi_barbero()));

-- Para los clientes: fotos visibles de barberos activos, las más nuevas primero
create or replace function public.fotos_publicas() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x order by x.creado_en desc), '[]'::json) from (
    select f.id, f.ruta, f.descripcion, f.barbero_id, b.nombre as barbero, f.creado_en
      from fotos_cortes f join barberos b on b.id = f.barbero_id
     where f.visible and b.activo
     order by f.creado_en desc
     limit 120
  ) x
$$;
revoke all on function public.fotos_publicas() from public;
grant execute on function public.fotos_publicas() to anon, authenticated;

-- ---------- La carpeta de fotos (Storage) ----------
-- Pública para ver; para subir o borrar hay que ser del equipo, y cada barbero solo en su carpeta.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('cortes', 'cortes', true, 3145728, array['image/jpeg', 'image/webp', 'image/png'])
on conflict (id) do update set public = true, file_size_limit = 3145728, allowed_mime_types = array['image/jpeg', 'image/webp', 'image/png'];

drop policy if exists cortes_subir on storage.objects;
drop policy if exists cortes_borrar on storage.objects;
create policy cortes_subir on storage.objects for insert to authenticated
    with check (bucket_id = 'cortes' and (public.mi_rol() = 'admin'
      or (public.mi_barbero() is not null and (storage.foldername(name))[1] = public.mi_barbero()::text)));
create policy cortes_borrar on storage.objects for delete to authenticated
    using (bucket_id = 'cortes' and (public.mi_rol() = 'admin'
      or (public.mi_barbero() is not null and (storage.foldername(name))[1] = public.mi_barbero()::text)));
