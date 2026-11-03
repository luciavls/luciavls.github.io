-- Mis tareas: preparación de la base de datos y del almacén de archivos.
-- Pega TODO este texto en Supabase → SQL Editor → New query y pulsa «Run».

-- 1) Tabla de tareas: cada fila pertenece a un usuario
create table if not exists public.tasks (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title       text not null,
  proj        text not null default '',
  due         date,
  state       text not null default 'todo' check (state in ('todo','doing','done')),
  notes       text not null default '',
  files       jsonb not null default '[]'::jsonb,
  done_at     timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Por si la tabla ya existía de antes
alter table public.tasks add column if not exists done_at timestamptz;

-- 2) Archivos sueltos (sin tarea asignada)
create table if not exists public.loose_files (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name      text not null,
  size      bigint not null default 0,
  type      text not null default '',
  path      text not null,
  added_at  timestamptz not null default now()
);

-- 3) Seguridad: cada persona solo ve y cambia lo suyo
alter table public.tasks enable row level security;
alter table public.loose_files enable row level security;

drop policy if exists "tareas propias" on public.tasks;
create policy "tareas propias" on public.tasks
  for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "archivos sueltos propios" on public.loose_files;
create policy "archivos sueltos propios" on public.loose_files
  for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 4) Almacén privado de archivos (cualquier formato, hasta 50 MB por archivo)
insert into storage.buckets (id, name, public, file_size_limit)
values ('archivos', 'archivos', false, 52428800)
on conflict (id) do nothing;

-- Cada usuario solo puede tocar la carpeta con su propio id
drop policy if exists "leer mis archivos" on storage.objects;
create policy "leer mis archivos" on storage.objects for select to authenticated
  using (bucket_id = 'archivos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "subir mis archivos" on storage.objects;
create policy "subir mis archivos" on storage.objects for insert to authenticated
  with check (bucket_id = 'archivos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "cambiar mis archivos" on storage.objects;
create policy "cambiar mis archivos" on storage.objects for update to authenticated
  using (bucket_id = 'archivos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "borrar mis archivos" on storage.objects;
create policy "borrar mis archivos" on storage.objects for delete to authenticated
  using (bucket_id = 'archivos' and (storage.foldername(name))[1] = auth.uid()::text);

-- 5) Sincronización con el Calendario del iPhone (suscripción .ics)
create table if not exists public.calendar_tokens (
  user_id    uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  token      uuid not null unique default gen_random_uuid(),
  created_at timestamptz not null default now()
);
alter table public.calendar_tokens enable row level security;
drop policy if exists "enlace propio" on public.calendar_tokens;
create policy "enlace propio" on public.calendar_tokens
  for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Tipo de respuesta text/calendar para que el iPhone lo reconozca
do $$ begin
  if not exists (select 1 from pg_type where typname = 'text/calendar') then
    create domain "text/calendar" as text;
  end if;
end $$;

create or replace function public.ics_escape(s text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(s, ''), E'\\', E'\\\\'), ';', E'\;'), ',', E'\\,'), E'\r', ''), E'\n', E'\\n')
$$;

-- Devuelve las tareas con fecha de quien tenga ese enlace secreto
create or replace function public.calendario(token uuid) returns "text/calendar"
language sql stable security definer set search_path = public as $$
  select concat_ws(E'\r\n',
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Mis tareas//ES', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    'X-WR-CALNAME:Mis tareas', 'X-WR-TIMEZONE:Europe/Madrid',
    'REFRESH-INTERVAL;VALUE=DURATION:PT15M', 'X-PUBLISHED-TTL:PT15M',
    (select string_agg(concat_ws(E'\r\n',
        'BEGIN:VEVENT',
        'UID:' || t.id || '@luciavls.github.io',
        'DTSTAMP:' || to_char(t.updated_at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"'),
        'LAST-MODIFIED:' || to_char(t.updated_at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"'),
        'DTSTART;VALUE=DATE:' || to_char(t.due, 'YYYYMMDD'),
        'DTEND;VALUE=DATE:' || to_char(t.due + 1, 'YYYYMMDD'),
        'SUMMARY:' || public.ics_escape(case when t.state = 'done' then '✓ ' else '' end || t.title),
        'DESCRIPTION:' || public.ics_escape(concat_ws(E'\n',
            nullif(t.proj, ''),
            case t.state when 'todo' then 'Pendiente' when 'doing' then 'En proceso' else 'Completada' end,
            nullif(t.notes, ''))),
        case when t.proj <> '' then 'CATEGORIES:' || public.ics_escape(t.proj) end,
        'TRANSP:TRANSPARENT',
        case when t.state <> 'done' then E'BEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:' || public.ics_escape(t.title) || E'\r\nTRIGGER:PT9H\r\nEND:VALARM' end,
        'END:VEVENT'), E'\r\n' order by t.due)
     from public.tasks t
     join public.calendar_tokens c on c.user_id = t.user_id
     where c.token = calendario.token and t.due is not null and t.due > current_date - 365),
    'END:VCALENDAR') || E'\r\n'
$$;
revoke all on function public.calendario(uuid) from public;
grant execute on function public.calendario(uuid) to anon, authenticated;
