-- rls_manual.sql — Pruebas manuales de RLS con dos usuarios. NO se ejecuta automáticamente.
-- Ejecutar en el SQL editor / psql contra una base de datos de pruebas, bloque a bloque.
-- Cada bloque es begin; ... rollback; y no deja datos.
--
-- Sustituye los placeholders (uuids de usuarios existentes en auth.users):
--   <USER_A_UUID>  usuario permanente A
--   <USER_B_UUID>  usuario permanente B (ajeno al grupo de A)
--   <ANON_UUID>    usuario anónimo (signInAnonymously)
-- Los uuids de grupo/miembro/gasto se generan dentro de cada bloque.

-- Helper de cada bloque: simular sesión de un usuario.
--   set local role authenticated;
--   select set_config('request.jwt.claims', '{"sub":"<UUID>","role":"authenticated","is_anonymous":false}', true);

-- ===========================================================================
-- 1. B no ve el grupo, miembros, gastos ni repartos de A
-- ===========================================================================
begin;
  set local role authenticated;
  select set_config('request.jwt.claims', '{"sub":"<USER_A_UUID>","role":"authenticated","is_anonymous":false}', true);
  select public.create_group('Grupo de prueba', 'A') as gid \gset
  select m.id as mid from public.members m where m.group_id = :'gid' \gset
  select public.create_expense(:'gid', :'mid', 1000, 'Cena', current_date,
    jsonb_build_array(jsonb_build_object('member_id', :'mid', 'share_cents', 1000))) as eid \gset

  -- A ve 1 fila en cada tabla.
  select count(*) as a_groups   from public.groups   where id = :'gid';          -- esperado 1
  select count(*) as a_members  from public.members  where group_id = :'gid';    -- esperado 1
  select count(*) as a_expenses from public.expenses where group_id = :'gid';    -- esperado 1
  select count(*) as a_splits   from public.expense_splits where group_id = :'gid'; -- esperado 1

  select set_config('request.jwt.claims', '{"sub":"<USER_B_UUID>","role":"authenticated","is_anonymous":false}', true);
  select count(*) as b_groups   from public.groups   where id = :'gid';          -- esperado 0
  select count(*) as b_members  from public.members  where group_id = :'gid';    -- esperado 0
  select count(*) as b_expenses from public.expenses where group_id = :'gid';    -- esperado 0
  select count(*) as b_splits   from public.expense_splits where group_id = :'gid'; -- esperado 0
rollback;

-- ===========================================================================
-- 2. B no puede escribir en el grupo de A (ni directo ni por función)
-- ===========================================================================
begin;
  set local role authenticated;
  select set_config('request.jwt.claims', '{"sub":"<USER_A_UUID>","role":"authenticated","is_anonymous":false}', true);
  select public.create_group('Grupo de prueba', 'A') as gid \gset
  select m.id as mid from public.members m where m.group_id = :'gid' \gset

  select set_config('request.jwt.claims', '{"sub":"<USER_B_UUID>","role":"authenticated","is_anonymous":false}', true);
  -- esperado: ERROR 42501 "No eres miembro de este grupo"
  select public.create_expense(:'gid', :'mid', 500, 'Intruso', current_date,
    jsonb_build_array(jsonb_build_object('member_id', :'mid', 'share_cents', 500)));
  -- esperado: ERROR por RLS (members_insert exige is_group_member)
  insert into public.members (group_id, display_name) values (:'gid', 'Intruso');
  -- esperado: 0 filas afectadas (members_update filtra por is_group_member)
  update public.members set display_name = 'Hackeado' where id = :'mid';
  -- esperado: ERROR permission denied (sin privilegio de escritura sobre expenses)
  insert into public.expenses (group_id, paid_by, amount_cents, description, spent_on)
    values (:'gid', :'mid', 1, 'x', current_date);
rollback;

-- ===========================================================================
-- 3. Gasto borrado (soft delete): ni el gasto ni sus repartos son visibles
-- ===========================================================================
begin;
  set local role authenticated;
  select set_config('request.jwt.claims', '{"sub":"<USER_A_UUID>","role":"authenticated","is_anonymous":false}', true);
  select public.create_group('Grupo de prueba', 'A') as gid \gset
  select m.id as mid from public.members m where m.group_id = :'gid' \gset
  select public.create_expense(:'gid', :'mid', 1000, 'Cena', current_date,
    jsonb_build_array(jsonb_build_object('member_id', :'mid', 'share_cents', 1000))) as eid \gset

  -- Marcar como borrado con rol de servicio (los usuarios no tienen UPDATE en expenses).
  reset role;
  update public.expenses set deleted_at = now() where id = :'eid';

  set local role authenticated;
  select set_config('request.jwt.claims', '{"sub":"<USER_A_UUID>","role":"authenticated","is_anonymous":false}', true);
  select count(*) as a_expenses from public.expenses where id = :'eid';              -- esperado 0
  select count(*) as a_splits   from public.expense_splits where expense_id = :'eid'; -- esperado 0
rollback;

-- ===========================================================================
-- 4. create_group rechaza usuarios anónimos
-- ===========================================================================
begin;
  set local role authenticated;
  select set_config('request.jwt.claims', '{"sub":"<ANON_UUID>","role":"authenticated","is_anonymous":true}', true);
  -- esperado: ERROR 42501 "Los usuarios anónimos no pueden crear grupos"
  select public.create_group('Grupo anónimo', 'Invitado');
rollback;

-- ===========================================================================
-- 5. create_expense NO rechaza anónimos que son miembros
--    (un anónimo solo puede ser miembro si se vincula a un members.user_id;
--     aquí se vincula con rol de servicio para simular la futura invitación)
-- ===========================================================================
begin;
  set local role authenticated;
  select set_config('request.jwt.claims', '{"sub":"<USER_A_UUID>","role":"authenticated","is_anonymous":false}', true);
  select public.create_group('Grupo de prueba', 'A') as gid \gset
  select m.id as mid from public.members m where m.group_id = :'gid' \gset

  reset role;
  insert into public.members (group_id, display_name, user_id)
    values (:'gid', 'Invitado', '<ANON_UUID>') returning id as amid \gset

  set local role authenticated;
  select set_config('request.jwt.claims', '{"sub":"<ANON_UUID>","role":"authenticated","is_anonymous":true}', true);
  -- esperado: devuelve un uuid (sin error)
  select public.create_expense(:'gid', :'amid', 700, 'Café', current_date,
    jsonb_build_array(jsonb_build_object('member_id', :'amid', 'share_cents', 700)));
rollback;

-- ===========================================================================
-- 6. create_expense rechaza más de 30 repartos (errcode 22023)
-- ===========================================================================
begin;
  set local role authenticated;
  select set_config('request.jwt.claims', '{"sub":"<USER_A_UUID>","role":"authenticated","is_anonymous":false}', true);
  select public.create_group('Grupo de prueba', 'A') as gid \gset
  select m.id as mid from public.members m where m.group_id = :'gid' \gset

  -- 31 elementos (se rechaza por tamaño antes de validar contenido).
  -- esperado: ERROR 22023 "El reparto no puede tener más de 30 elementos (recibidos: 31)"
  select public.create_expense(:'gid', :'mid', 31, 'Muchos', current_date,
    (select jsonb_agg(jsonb_build_object('member_id', :'mid', 'share_cents', 1))
     from generate_series(1, 31)));
rollback;

-- ===========================================================================
-- 7. Checks de longitud sobre btrim()
-- ===========================================================================
begin;
  set local role authenticated;
  select set_config('request.jwt.claims', '{"sub":"<USER_A_UUID>","role":"authenticated","is_anonymous":false}', true);
  -- esperado: ERROR 23514 (check violation) por nombre solo con espacios
  select public.create_group('   ', 'A');
rollback;

begin;
  set local role authenticated;
  select set_config('request.jwt.claims', '{"sub":"<USER_A_UUID>","role":"authenticated","is_anonymous":false}', true);
  -- esperado: ERROR 23514 por display_name solo con espacios
  select public.create_group('Grupo', '   ');
rollback;

begin;
  set local role authenticated;
  select set_config('request.jwt.claims', '{"sub":"<USER_A_UUID>","role":"authenticated","is_anonymous":false}', true);
  select public.create_group('Grupo de prueba', 'A') as gid \gset
  select m.id as mid from public.members m where m.group_id = :'gid' \gset
  -- esperado: ERROR 23514 por description solo con espacios
  select public.create_expense(:'gid', :'mid', 100, '   ', current_date,
    jsonb_build_array(jsonb_build_object('member_id', :'mid', 'share_cents', 100)));
rollback;
