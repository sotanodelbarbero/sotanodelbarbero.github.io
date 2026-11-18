-- =========================================================
--  Todo en tiempo real.
--  Pegar todo en Supabase > SQL Editor > Run (después de 13_turno_dia.sql).
--  Se puede volver a ejecutar sin problema.
--
--  1) El panel escucha también precios, barberos, horario, turnos y caja.
--  2) Las páginas de los clientes reciben un aviso público de «algo cambió»
--     (sin nombres ni teléfonos) y se actualizan al momento:
--       tema 'fila'   → cambió la fila de hoy (turnos)
--       tema 'agenda' → cambiaron citas, bloqueos, horario, turnos o servicios
--     Si el aviso fallara por cualquier motivo, NO afecta al guardado.
-- =========================================================

-- 1) Tablas que el panel escucha en vivo
do $$
declare t text;
begin
  foreach t in array array['visitas','citas','bloqueos','productos','ventas_productos','servicios','barberos',
                           'horario','horario_especial','barbero_turno','barbero_turno_dia','gastos','cortes'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; when undefined_table then null; when undefined_object then null;
    end;
  end loop;
end $$;

-- 2) Aviso público sin datos personales (Realtime Broadcast desde la base de datos)
create or replace function public._avisar_cambio() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    perform realtime.send(jsonb_build_object('tabla', tg_table_name), 'cambio', tg_argv[0], false);
  exception when others then
    null;   -- sin Realtime o con error: el cambio se guarda igual
  end;
  return null;
end $$;
revoke all on function public._avisar_cambio() from public, anon, authenticated;

drop trigger if exists avisar_fila on public.visitas;
create trigger avisar_fila after insert or update or delete on public.visitas
  for each statement execute function public._avisar_cambio('fila');

do $$
declare t text;
begin
  foreach t in array array['citas','bloqueos','horario','horario_especial','barbero_turno','barbero_turno_dia','servicios','barberos'] loop
    execute format('drop trigger if exists avisar_agenda on public.%I', t);
    execute format('create trigger avisar_agenda after insert or update or delete on public.%I
                    for each statement execute function public._avisar_cambio(''agenda'')', t);
  end loop;
end $$;
-- Las citas también mueven la fila (una cita que llega entra a la fila)
drop trigger if exists avisar_fila on public.citas;
create trigger avisar_fila after insert or update or delete on public.citas
  for each statement execute function public._avisar_cambio('fila');
