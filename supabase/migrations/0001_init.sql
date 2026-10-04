-- 0001_init.sql — Esquema de la noche 1: groups, members, expenses, expense_splits.
-- Todo el dinero va en céntimos (bigint). Las escrituras de usuario pasan por funciones
-- security definer; las tablas solo exponen SELECT (y lo mínimo en members).

begin;

-- ---------------------------------------------------------------------------
-- TABLAS
-- ---------------------------------------------------------------------------

create table public.groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(btrim(name)) between 1 and 80),
  currency    char(3) not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now()
);

create table public.members (
  id            uuid primary key default gen_random_uuid(),
  group_id      uuid not null references public.groups on delete cascade,
  display_name  text not null check (char_length(btrim(display_name)) between 1 and 60),
  user_id       uuid references auth.users on delete set null,
  created_at    timestamptz not null default now(),
  unique (id, group_id),
  unique (group_id, user_id)
);

create table public.expenses (
  id            uuid primary key default gen_random_uuid(),
  group_id      uuid not null references public.groups on delete cascade,
  paid_by       uuid not null,
  amount_cents  bigint not null check (amount_cents > 0),
  description   text not null check (char_length(btrim(description)) between 1 and 120),
  spent_on      date not null,
  created_by    uuid references auth.users on delete set null,
  created_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  unique (id, group_id),
  -- El pagador debe ser miembro del MISMO grupo que el gasto.
  foreign key (paid_by, group_id) references public.members (id, group_id)
);

create table public.expense_splits (
  expense_id   uuid not null,
  member_id    uuid not null,
  group_id     uuid not null,
  share_cents  bigint not null check (share_cents >= 0),
  primary key (expense_id, member_id),
  -- Gasto y miembro deben pertenecer al mismo group_id.
  foreign key (expense_id, group_id) references public.expenses (id, group_id) on delete cascade,
  foreign key (member_id, group_id)  references public.members  (id, group_id)
);

create index members_user_id_idx        on public.members (user_id);
create index expenses_group_spent_idx   on public.expenses (group_id, spent_on desc);
create index expense_splits_member_idx  on public.expense_splits (member_id, group_id);

-- ---------------------------------------------------------------------------
-- PRIVILEGIOS DE TABLA
-- ---------------------------------------------------------------------------

revoke all on table public.groups, public.members, public.expenses, public.expense_splits
  from public, anon, authenticated;

grant select on table public.groups, public.members, public.expenses, public.expense_splits
  to authenticated;

-- members: alta solo de (group_id, display_name); user_id queda siempre null.
grant insert (group_id, display_name) on public.members to authenticated;
-- members: solo se puede editar display_name.
revoke update on public.members from authenticated;
grant update (display_name) on public.members to authenticated;

-- ---------------------------------------------------------------------------
-- FUNCIÓN AUXILIAR PARA RLS
-- ---------------------------------------------------------------------------

create function public.is_group_member(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.members m
    where m.group_id = p_group_id
      and m.user_id = auth.uid()
  );
$$;

revoke execute on function public.is_group_member(uuid) from public, anon;
grant  execute on function public.is_group_member(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.groups         enable row level security;
alter table public.members        enable row level security;
alter table public.expenses       enable row level security;
alter table public.expense_splits enable row level security;

create policy groups_select on public.groups
  for select to authenticated
  using (public.is_group_member(id));

create policy members_select on public.members
  for select to authenticated
  using (public.is_group_member(group_id));

create policy members_insert on public.members
  for insert to authenticated
  with check (user_id is null and public.is_group_member(group_id));

create policy members_update on public.members
  for update to authenticated
  using (public.is_group_member(group_id))
  with check (public.is_group_member(group_id));

create policy expenses_select on public.expenses
  for select to authenticated
  using (public.is_group_member(group_id) and deleted_at is null);

create policy expense_splits_select on public.expense_splits
  for select to authenticated
  using (
    public.is_group_member(group_id)
    and exists (
      select 1 from public.expenses e
      where e.id = expense_id
        and e.group_id = expense_splits.group_id
        and e.deleted_at is null
    )
  );

-- ---------------------------------------------------------------------------
-- FUNCIONES DE ESCRITURA
-- ---------------------------------------------------------------------------

create function public.create_group(p_name text, p_creator_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_group uuid;
begin
  if v_uid is null then
    raise exception 'Hace falta iniciar sesión para crear un grupo'
      using errcode = '28000';
  end if;

  -- Los invitados anónimos no pueden crear grupos (claim is_anonymous del JWT).
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Los usuarios anónimos no pueden crear grupos'
      using errcode = '42501';
  end if;

  insert into public.groups (name, created_by)
  values (p_name, v_uid)
  returning id into v_group;

  insert into public.members (group_id, display_name, user_id)
  values (v_group, p_creator_name, v_uid);

  return v_group;
end;
$$;

revoke execute on function public.create_group(text, text) from public, anon;
grant  execute on function public.create_group(text, text) to authenticated;

create function public.create_expense(
  p_group_id     uuid,
  p_paid_by      uuid,
  p_amount_cents bigint,
  p_description  text,
  p_spent_on     date,
  p_splits       jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_expense uuid;
  v_elem    jsonb;
  v_idx     int := 0;
  v_member  uuid;
  v_share   bigint;
  v_total   numeric := 0;
  v_seen    uuid[] := '{}';
  v_bad     uuid;
begin
  if v_uid is null then
    raise exception 'Hace falta iniciar sesión para crear un gasto'
      using errcode = '28000';
  end if;

  -- Mismo mensaje si el grupo no existe o si no eres miembro: no revela existencia.
  if not public.is_group_member(p_group_id) then
    raise exception 'No eres miembro de este grupo'
      using errcode = '42501';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'El importe debe ser mayor que 0 céntimos (recibido: %)', p_amount_cents
      using errcode = '22023';
  end if;

  if p_paid_by is null or not exists (
    select 1 from public.members m
    where m.id = p_paid_by and m.group_id = p_group_id
  ) then
    raise exception 'El pagador % no es miembro del grupo', p_paid_by
      using errcode = '22023';
  end if;

  if p_splits is null or jsonb_typeof(p_splits) <> 'array' or jsonb_array_length(p_splits) = 0 then
    raise exception 'El reparto debe ser un array JSON no vacío'
      using errcode = '22023';
  end if;

  if jsonb_array_length(p_splits) > 30 then
    raise exception 'El reparto no puede tener más de 30 elementos (recibidos: %)', jsonb_array_length(p_splits)
      using errcode = '22023';
  end if;

  for v_elem in select value from jsonb_array_elements(p_splits) loop
    v_idx := v_idx + 1;

    if jsonb_typeof(v_elem) <> 'object' then
      raise exception 'Reparto #%: debe ser un objeto {member_id, share_cents}', v_idx
        using errcode = '22023';
    end if;

    if jsonb_typeof(v_elem -> 'member_id') is distinct from 'string'
       or (v_elem ->> 'member_id') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      raise exception 'Reparto #%: member_id debe ser un uuid', v_idx
        using errcode = '22023';
    end if;

    if jsonb_typeof(v_elem -> 'share_cents') is distinct from 'number'
       or (v_elem ->> 'share_cents') !~ '^-?[0-9]{1,18}$' then
      raise exception 'Reparto #%: share_cents debe ser un entero en céntimos', v_idx
        using errcode = '22023';
    end if;

    v_member := (v_elem ->> 'member_id')::uuid;
    v_share  := (v_elem ->> 'share_cents')::bigint;

    if v_share < 0 then
      raise exception 'Reparto #%: share_cents no puede ser negativo (recibido: %)', v_idx, v_share
        using errcode = '22023';
    end if;

    if v_member = any (v_seen) then
      raise exception 'Reparto #%: el miembro % aparece repetido', v_idx, v_member
        using errcode = '22023';
    end if;

    v_seen  := v_seen || v_member;
    v_total := v_total + v_share;
  end loop;

  select t.id into v_bad
  from unnest(v_seen) as t(id)
  where not exists (
    select 1 from public.members m
    where m.id = t.id and m.group_id = p_group_id
  )
  limit 1;

  if found then
    raise exception 'El miembro % del reparto no pertenece al grupo', v_bad
      using errcode = '22023';
  end if;

  if v_total <> p_amount_cents then
    raise exception 'La suma del reparto (%) no coincide con el importe (%)', v_total, p_amount_cents
      using errcode = '22023';
  end if;

  insert into public.expenses (group_id, paid_by, amount_cents, description, spent_on, created_by)
  values (p_group_id, p_paid_by, p_amount_cents, p_description, p_spent_on, v_uid)
  returning id into v_expense;

  insert into public.expense_splits (expense_id, member_id, group_id, share_cents)
  select v_expense, (e ->> 'member_id')::uuid, p_group_id, (e ->> 'share_cents')::bigint
  from jsonb_array_elements(p_splits) as e;

  return v_expense;
end;
$$;

revoke execute on function public.create_expense(uuid, uuid, bigint, text, date, jsonb) from public, anon;
grant  execute on function public.create_expense(uuid, uuid, bigint, text, date, jsonb) to authenticated;

commit;
