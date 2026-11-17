-- =========================================================
--  Equipo: comisión congelada en cada cobro y hora de atención.
--  Pegar todo en Supabase > SQL Editor > Run (después de 09_calendario.sql).
--  Se puede volver a ejecutar sin problema.
--
--  - comision_pct: el % del barbero EN EL MOMENTO del cobro. Si después
--    cambias su comisión, los cortes y reportes pasados no se mueven.
--  - atendido_en: cuándo se empezó a atender (para "atendiendo hace 12 min"
--    y el tiempo promedio por corte).
-- =========================================================

alter table public.visitas add column if not exists comision_pct numeric(5,2)
  check (comision_pct is null or comision_pct between 0 and 100);
alter table public.visitas add column if not exists atendido_en timestamptz;

-- Cobros que ya existían: se les pone el % que tiene hoy su barbero
update public.visitas v set comision_pct = b.comision_pct
  from public.barberos b
 where v.estado = 'cobrado' and v.comision_pct is null and b.id = v.barbero_id;

create or replace function public._sellar_atencion() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Empieza a atenderse
  if new.estado = 'atendiendo' and (tg_op = 'INSERT' or old.estado is distinct from 'atendiendo') then
    new.atendido_en := now();
  end if;
  -- Al cobrar (o si el admin cambia el barbero de un cobro) se congela el % de ese barbero
  if new.estado = 'cobrado' and (tg_op = 'INSERT' or old.estado is distinct from 'cobrado'
                                 or new.barbero_id is distinct from old.barbero_id) then
    new.comision_pct := (select comision_pct from barberos where id = new.barbero_id);
  elsif tg_op = 'UPDATE' and public.mi_rol() is distinct from 'admin' then
    new.comision_pct := old.comision_pct;      -- nadie más lo puede cambiar a mano
  end if;
  if new.estado = 'espera' then new.atendido_en := null; end if;
  return new;
end $$;
drop trigger if exists sellar_atencion on public.visitas;
create trigger sellar_atencion before insert or update on public.visitas
  for each row execute function public._sellar_atencion();
revoke all on function public._sellar_atencion() from public, anon, authenticated;
