-- =========================================================
--  Llegada del cliente con cita.
--  Pegar todo en Supabase > SQL Editor > Run (después de 10_equipo.sql).
--  Se puede volver a ejecutar sin problema.
--
--  - El cliente puede tocar "Ya llegué" en su cita (desde 45 min antes
--    hasta 30 min después de su hora) y entra a la fila con prioridad.
--  - Si alguien con cita hoy toma turno con el QR usando su teléfono,
--    se toma como su llegada (no queda dos veces).
--  - El cliente puede seguir su turno después de llegar.
-- =========================================================

-- Pasar una cita a la fila de hoy (lo usan el personal y el cliente)
create or replace function public._pasar_a_fila(p_id bigint) returns visitas
language plpgsql security definer set search_path = public as $$
declare
  c citas;
  v_turno int;
  v visitas;
begin
  select * into c from citas where id = p_id for update;
  if not found then raise exception 'La cita no existe'; end if;
  if c.estado <> 'agendada' then raise exception 'La cita ya no está pendiente'; end if;
  if c.fecha <> hoy_local() then raise exception 'La cita no es de hoy'; end if;

  v_turno := public.registrar_visita(c.cliente_nombre, c.telefono, c.servicio_id);
  update visitas set barbero_id = c.barbero_id, hora_cita = c.hora
   where fecha = hoy_local() and turno = v_turno
  returning * into v;
  update citas set estado = 'llego', visita_id = v.id where id = c.id;
  return v;
end $$;

-- Personal: botón "Llegó" del panel (misma regla de siempre)
create or replace function public.llegada_cita(p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
begin
  if public.mi_rol() is null then raise exception 'Sin permiso'; end if;
  return (public._pasar_a_fila(p_id)).turno;
end $$;

-- ¿Ya puede marcar que llegó? De 45 min antes a 30 min después de su hora, y con la barbería abierta
create or replace function public._puede_llegar(c citas) returns boolean
language sql stable security definer set search_path = public as $$
  select c.estado = 'agendada' and c.fecha = hoy_local()
     and ahora_local() >= (c.fecha + c.hora) - interval '45 minutes'
     and ahora_local() <= (c.fecha + c.hora) + interval '30 minutes'
     and (public._abierto_hoy()->>'abierto')::boolean
$$;

-- Cliente: "Ya llegué"
create or replace function public.llegue_cita(p_token uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  c citas;
  v visitas;
begin
  select * into c from citas where token = p_token;
  if not found then raise exception 'La cita no existe'; end if;
  if c.estado = 'llego' then   -- ya había llegado: regresa su turno
    select * into v from visitas where id = c.visita_id;
    return json_build_object('turno', v.turno, 'token', v.token, 'fecha', v.fecha, 'repetido', true);
  end if;
  if c.estado <> 'agendada' then raise exception 'La cita ya no está pendiente'; end if;
  if c.fecha <> hoy_local() then raise exception 'La cita no es de hoy'; end if;
  if ahora_local() < (c.fecha + c.hora) - interval '45 minutes' then raise exception 'Todavía es temprano'; end if;
  if ahora_local() > (c.fecha + c.hora) + interval '30 minutes' then raise exception 'Ya pasó tu hora'; end if;
  if not (public._abierto_hoy()->>'abierto')::boolean then raise exception 'Cerrado'; end if;
  v := public._pasar_a_fila(c.id);
  return json_build_object('turno', v.turno, 'token', v.token, 'fecha', v.fecha);
end $$;

-- Consultar mi cita: ahora dice si ya puede llegar y, si ya llegó, el turno para seguirlo
create or replace function public.estado_cita(p_token uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'fecha',    c.fecha,
    'hora',     to_char(c.fecha + c.hora, 'HH24:MI'),
    'duracion', c.duracion_min,
    'estado',   case when c.estado = 'agendada' and (c.fecha + c.hora) < ahora_local() - interval '2 hours'
                     then 'no_vino' else c.estado end,
    'nombre',   split_part(c.cliente_nombre, ' ', 1),
    'servicio', s.nombre,
    'precio',   s.precio,
    'barbero',  b.nombre,
    'cancelable', c.estado = 'agendada' and (c.fecha + c.hora) > ahora_local(),
    'pasada',   (c.fecha + c.hora) < ahora_local() - interval '2 hours',
    'puede_llegar', public._puede_llegar(c),
    'llegar_desde', to_char((c.fecha + c.hora) - interval '45 minutes', 'HH24:MI'),
    'turno',    v.turno,
    'turno_token', v.token,
    'turno_estado', v.estado
  )
  from citas c
  join servicios s on s.id = c.servicio_id
  left join barberos b on b.id = c.barbero_id
  left join visitas v on v.id = c.visita_id
  where c.token = p_token
$$;

-- Tomar turno con el QR: si ese teléfono tiene cita hoy y ya es su hora, cuenta como su llegada
create or replace function public.registrar_turno(
  p_nombre text, p_telefono text, p_servicio_id bigint
) returns json
language plpgsql security definer set search_path = public as $$
declare
  tel   text := nullif(regexp_replace(coalesce(p_telefono, ''), '[^0-9+]', '', 'g'), '');
  ya    visitas;
  cit   citas;
  v     visitas;
  est   json;
  h     horario := public._horario_dia(hoy_local());
  dur   int;
  v_turno int;
  v_token uuid;
begin
  if tel is not null then
    -- Mismo teléfono con un turno activo hoy: se le regresa ese mismo turno
    select * into ya from visitas
     where fecha = hoy_local() and telefono = left(tel, 20) and estado in ('espera','atendiendo')
     order by turno desc limit 1;
    if found then return json_build_object('turno', ya.turno, 'token', ya.token, 'repetido', true); end if;

    -- Tiene cita hoy y ya es su ventana de llegada: entra con la prioridad de su cita
    select * into cit from citas c
     where c.telefono = regexp_replace(tel, '[^0-9]', '', 'g') and public._puede_llegar(c)
     order by c.hora limit 1;
    if found then
      v := public._pasar_a_fila(cit.id);
      return json_build_object('turno', v.turno, 'token', v.token, 'de_cita', true, 'hora_cita', to_char(cit.fecha + cit.hora, 'HH24:MI'));
    end if;
  end if;

  est := public._abierto_hoy();
  if not (est->>'abierto')::boolean then raise exception 'Cerrado'; end if;
  select coalesce(duracion_min, 30) into dur from servicios where id = p_servicio_id and activo;
  if ahora_local()::time + make_interval(mins => public._espera(hoy_local(), null) + coalesce(dur, 30)) > h.cierra then
    raise exception 'Ya no alcanza el tiempo hoy';
  end if;

  v_turno := public.registrar_visita(p_nombre, p_telefono, p_servicio_id);
  select token into v_token from visitas where fecha = hoy_local() and turno = v_turno;
  return json_build_object('turno', v_turno, 'token', v_token);
end $$;

-- ---------- Permisos ----------
revoke all on function public._pasar_a_fila(bigint) from public, anon, authenticated;
revoke all on function public._puede_llegar(citas) from public, anon, authenticated;
revoke all on function public.llegada_cita(bigint) from public, anon;
revoke all on function public.llegue_cita(uuid) from public;
revoke all on function public.estado_cita(uuid) from public;
revoke all on function public.registrar_turno(text,text,bigint) from public;
grant execute on function public.llegada_cita(bigint) to authenticated;
grant execute on function public.llegue_cita(uuid) to anon, authenticated;
grant execute on function public.estado_cita(uuid) to anon, authenticated;
grant execute on function public.registrar_turno(text,text,bigint) to anon, authenticated;
