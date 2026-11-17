-- =========================================================
--  Lado del cliente: seguimiento de turno en vivo
--  Pegar todo en Supabase > SQL Editor > Run (después de 04_admin.sql).
--
--  El cliente NO tiene acceso a la tabla de visitas. Al registrarse recibe
--  un "token" secreto (solo su celular lo tiene) y con él puede consultar
--  o cancelar SU turno y nada más.
-- =========================================================

-- Duración de cada servicio (para calcular el tiempo de espera)
alter table public.servicios
  add column if not exists duracion_min int not null default 30
  check (duracion_min between 5 and 240);

-- Token secreto por visita
alter table public.visitas
  add column if not exists token uuid not null default gen_random_uuid();
create unique index if not exists visitas_token_idx on public.visitas (token);

-- Barberos que trabajan hoy (para repartir la espera). Mínimo 1.
create or replace function public._barberos_hoy() returns int
language sql stable security definer set search_path = public as $$
  select greatest(1, count(*))::int from barberos where activo
$$;

-- Minutos estimados de espera para quien está en la posición indicada.
-- Suma la duración de los que esperan antes + la mitad de los que ya se atienden,
-- y lo reparte entre los barberos activos.
create or replace function public._minutos_espera(p_fecha date, p_antes_de int) returns int
language sql stable security definer set search_path = public as $$
  select ceil((
      coalesce(sum(case when v.estado = 'espera' and v.turno < p_antes_de then s.duracion_min end), 0)
    + coalesce(sum(case when v.estado = 'atendiendo' then s.duracion_min end), 0) / 2.0
  ) / public._barberos_hoy())::int
  from visitas v left join servicios s on s.id = v.servicio_id
  where v.fecha = p_fecha
$$;

-- ---------- Antes de registrarse: ¿cuánta gente hay? ----------
create or replace function public.cola_publica() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'esperando', (select count(*) from visitas where fecha = hoy_local() and estado = 'espera'),
    'minutos',   public._minutos_espera(hoy_local(), 2147483647)
  )
$$;

-- ---------- Registrarse: devuelve número de turno y token ----------
create or replace function public.registrar_turno(
  p_nombre text, p_telefono text, p_servicio_id bigint
) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_turno int := public.registrar_visita(p_nombre, p_telefono, p_servicio_id);
  v_token uuid;
begin
  select token into v_token from visitas where fecha = hoy_local() and turno = v_turno;
  return json_build_object('turno', v_turno, 'token', v_token);
end $$;

-- ---------- Consultar mi turno ----------
create or replace function public.estado_turno(p_token uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'turno',     v.turno,
    'fecha',     v.fecha,
    'es_hoy',    v.fecha = hoy_local(),
    'estado',    v.estado,
    'nombre',    split_part(v.cliente_nombre, ' ', 1),
    'servicio',  s.nombre,
    'precio',    s.precio,
    'barbero',   b.nombre,
    'antes',     (select count(*) from visitas w
                   where w.fecha = v.fecha and w.estado = 'espera' and w.turno < v.turno),
    'minutos',   case when v.estado = 'espera' then public._minutos_espera(v.fecha, v.turno) end
  )
  from visitas v
  left join servicios s on s.id = v.servicio_id
  left join barberos  b on b.id = v.barbero_id
  where v.token = p_token
$$;

-- ---------- Cancelar mi turno (solo si todavía está en espera) ----------
create or replace function public.cancelar_turno(p_token uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update visitas set estado = 'cancelado'
   where token = p_token and estado = 'espera' and fecha = hoy_local();
  return found;
end $$;

-- Permisos: el cliente (anon) solo puede usar estas funciones
revoke all on function public._barberos_hoy() from public, anon, authenticated;
revoke all on function public._minutos_espera(date,int) from public, anon, authenticated;
revoke all on function public.cola_publica() from public;
revoke all on function public.registrar_turno(text,text,bigint) from public;
revoke all on function public.estado_turno(uuid) from public;
revoke all on function public.cancelar_turno(uuid) from public;
grant execute on function public.cola_publica() to anon, authenticated;
grant execute on function public.registrar_turno(text,text,bigint) to anon, authenticated;
grant execute on function public.estado_turno(uuid) to anon, authenticated;
grant execute on function public.cancelar_turno(uuid) to anon, authenticated;
