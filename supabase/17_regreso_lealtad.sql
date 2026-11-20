-- =========================================================
--  Que el cliente regrese: «Te toca corte» y tarjeta de lealtad.
--  Pegar todo en Supabase > SQL Editor > Run (después de 16_recordatorios.sql).
--  Se puede volver a ejecutar sin problema.
--
--  - Tarjeta de lealtad: cada corte cobrado es un sello (contado por teléfono).
--    Al juntar los sellos (10, por ejemplo) le toca su premio (corte gratis).
--    El cliente ve sus sellos en su turno y en su cita; el panel avisa al cobrar.
--  - «Te toca corte»: guarda a quién ya se le escribió para invitarlo a regresar,
--    para no escribirle dos veces.
-- =========================================================

-- ---------- Ajustes de la tarjeta (una sola fila) ----------
create table if not exists public.lealtad (
  id      int primary key default 1 check (id = 1),
  activa  boolean not null default true,
  cada    int not null default 10 check (cada between 2 and 50),
  premio  text not null default 'Corte gratis' check (char_length(premio) between 2 and 60)
);
insert into public.lealtad (id) values (1) on conflict (id) do nothing;
alter table public.lealtad enable row level security;
drop policy if exists lealtad_staff_leer on public.lealtad;
drop policy if exists lealtad_admin on public.lealtad;
create policy lealtad_staff_leer on public.lealtad for select to authenticated using ((select public.mi_rol()) is not null);
create policy lealtad_admin on public.lealtad for update to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

-- Un cobro marcado como premio (corte gratis) no cuenta como sello
alter table public.visitas add column if not exists canje_lealtad boolean not null default false;

-- Teléfono comparable: solo los últimos 10 dígitos (así «+52 55…» y «55…» son el mismo cliente)
create or replace function public._tel10(t text) returns text
language sql immutable as $$ select nullif(right(regexp_replace(coalesce(t, ''), '[^0-9]', '', 'g'), 10), '') $$;
create index if not exists visitas_tel10_idx on public.visitas (public._tel10(telefono)) where estado = 'cobrado';

-- Sellos de un teléfono: pagados (cobros con monto, sin contar premios), premios ya usados y si le toca
create or replace function public._sellos(p_tel text) returns json
language sql stable security definer set search_path = public as $$
  with l as (select * from lealtad where id = 1),
       x as (select count(*) filter (where not canje_lealtad and coalesce(monto, 0) > 0) as pagados,
                    count(*) filter (where canje_lealtad) as canjes
               from visitas where estado = 'cobrado' and _tel10(telefono) = _tel10(p_tel))
  select case when l.activa and _tel10(p_tel) is not null then json_build_object(
    'cada', l.cada, 'premio', l.premio, 'pagados', x.pagados, 'canjes', x.canjes,
    'progreso', greatest(x.pagados - x.canjes * l.cada, 0),
    'toca', x.pagados - x.canjes * l.cada >= l.cada) end
  from l, x
$$;
revoke all on function public._sellos(text) from public, anon, authenticated;

-- Para el personal (al cobrar)
create or replace function public.sellos_telefono(p_tel text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if public.mi_rol() is null then raise exception 'Solo el personal'; end if;
  return public._sellos(p_tel);
end $$;
revoke all on function public.sellos_telefono(text) from public, anon;
grant execute on function public.sellos_telefono(text) to authenticated;

-- Para el cliente: con el enlace de su turno o de su cita (nunca con el teléfono)
create or replace function public.mis_sellos(p_token uuid) returns json
language sql stable security definer set search_path = public as $$
  select public._sellos(coalesce(
    (select telefono from visitas where token = p_token),
    (select telefono from citas where token = p_token)))
$$;
revoke all on function public.mis_sellos(uuid) from public;
grant execute on function public.mis_sellos(uuid) to anon, authenticated;

-- ---------- «Te toca corte»: a quién ya se le escribió ----------
create table if not exists public.regreso_contactos (
  tel        text primary key,
  enviado_en timestamptz not null default now(),
  por        uuid default auth.uid()
);
alter table public.regreso_contactos enable row level security;
drop policy if exists regreso_staff on public.regreso_contactos;
create policy regreso_staff on public.regreso_contactos for all to authenticated
  using ((select public.mi_rol()) is not null) with check ((select public.mi_rol()) is not null);

-- ---------- Resumen de clientes: igual que antes, más sus sellos ----------
create or replace view public.clientes_resumen with (security_invoker = true) as
select
  coalesce(telefono, 'nombre:' || lower(btrim(cliente_nombre)))          as clave,
  (array_agg(cliente_nombre order by creado_en desc))[1]                 as nombre,
  max(telefono)                                                          as telefono,
  count(*) filter (where estado = 'cobrado')                             as visitas,
  coalesce(sum(monto + propina) filter (where estado = 'cobrado'), 0)    as gastado,
  min(fecha)                                                             as primera_visita,
  max(fecha)                                                             as ultima_visita,
  count(*) filter (where estado = 'cobrado' and not canje_lealtad and coalesce(monto, 0) > 0) as pagados,
  count(*) filter (where estado = 'cobrado' and canje_lealtad)           as canjes
from public.visitas
where estado <> 'cancelado'
group by 1;
revoke all on public.clientes_resumen from anon;
grant select on public.clientes_resumen to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.lealtad;
exception when duplicate_object then null; when undefined_object then null; end $$;
