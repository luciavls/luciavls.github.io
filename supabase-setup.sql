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

-- 5) Calendarios del iPhone (iCloud) que se ven dentro de la app
create extension if not exists http with schema extensions;

create table if not exists public.external_calendars (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name       text not null default 'iPhone',
  url        text not null,
  color      text not null default '#8e8e93',
  created_at timestamptz not null default now()
);
alter table public.external_calendars enable row level security;
drop policy if exists "calendarios propios" on public.external_calendars;
create policy "calendarios propios" on public.external_calendars
  for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Descarga el calendario (el navegador no puede pedírselo a iCloud directamente)
create or replace function public.leer_calendario(cal uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  u text; r extensions.http_response; loc text; i int := 0;
begin
  select url into u from public.external_calendars where id = cal and user_id = auth.uid();
  if u is null then raise exception 'Calendario no encontrado'; end if;
  u := regexp_replace(trim(u), '^webcals?://', 'https://', 'i');
  begin perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000'); exception when others then null; end;
  loop
    if u !~* '^https://[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(:[0-9]+)?(/|\?|$)' then raise exception 'El enlace no es válido'; end if;
    r := extensions.http_get(u);
    exit when r.status not in (301, 302, 303, 307, 308) or i >= 5;
    select h.value into loc from unnest(r.headers) h where lower(h.field) = 'location' limit 1;
    exit when loc is null;
    u := loc; i := i + 1;
  end loop;
  if r.status <> 200 then raise exception 'El calendario respondió con el código %', r.status; end if;
  if position('BEGIN:VCALENDAR' in r.content) = 0 then raise exception 'Ese enlace no es un calendario'; end if;
  return r.content;
end $$;
revoke all on function public.leer_calendario(uuid) from public, anon;
grant execute on function public.leer_calendario(uuid) to authenticated;

-- 6) Portapapeles entre dispositivos (texto que copias aquí y pegas en otro sitio)
create table if not exists public.clips (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  content    text not null,
  device     text not null default '',
  created_at timestamptz not null default now()
);
alter table public.clips enable row level security;
drop policy if exists "portapapeles propio" on public.clips;
create policy "portapapeles propio" on public.clips
  for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
-- Para que lo que copias en un dispositivo aparezca al momento en los demás
do $$ begin
  alter publication supabase_realtime add table public.clips;
exception when duplicate_object then null; when undefined_object then null;
end $$;

-- 7) Logros: tus trabajos definitivos, privados (solo los ves tú, dentro de la app)
create table if not exists public.achievements (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title       text not null,
  cover_text  text not null default '',
  color       text not null default '#ee6a45',
  category    text not null default '',
  date        date,
  description text not null default '',
  files       jsonb not null default '[]'::jsonb,
  published   boolean not null default true,
  created_at  timestamptz not null default now()
);
alter table public.achievements enable row level security;
drop policy if exists "logros publicos" on public.achievements;
drop policy if exists "logros de la duena" on public.achievements;
drop policy if exists "logros propios" on public.achievements;
create policy "logros propios" on public.achievements for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop table if exists public.logros_owner;

-- Almacén PRIVADO de los archivos de logros
insert into storage.buckets (id, name, public, file_size_limit)
values ('logros', 'logros', false, 52428800)
on conflict (id) do update set public = false;
drop policy if exists "leer logros" on storage.objects;
create policy "leer logros" on storage.objects for select to authenticated
  using (bucket_id = 'logros' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "subir logros" on storage.objects;
create policy "subir logros" on storage.objects for insert to authenticated
  with check (bucket_id = 'logros' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "cambiar logros" on storage.objects;
create policy "cambiar logros" on storage.objects for update to authenticated
  using (bucket_id = 'logros' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "borrar logros" on storage.objects;
create policy "borrar logros" on storage.objects for delete to authenticated
  using (bucket_id = 'logros' and (storage.foldername(name))[1] = auth.uid()::text);

-- 8) Proyectos (puedes crear los tuyos desde la app)
create table if not exists public.projects (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name       text not null,
  group_name text not null default '',
  color      text not null default '#8e9097',
  created_at timestamptz not null default now(),
  unique (user_id, name)
);
alter table public.projects enable row level security;
drop policy if exists "proyectos propios" on public.projects;
create policy "proyectos propios" on public.projects for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 9) Subtareas (se guardan dentro de cada tarea)
alter table public.tasks add column if not exists subtasks jsonb not null default '[]'::jsonb;

-- 10) Pomodoros: cada bloque de foco que terminas (para ver cuántos haces cada día)
create table if not exists public.pomodoros (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  task_id    uuid references public.tasks(id) on delete set null,
  started_at timestamptz not null default now(),
  minutes    int not null default 60,
  kind       text not null default 'focus',
  created_at timestamptz not null default now()
);
create index if not exists pomodoros_user_started on public.pomodoros (user_id, started_at);
alter table public.pomodoros enable row level security;
drop policy if exists "pomodoros propios" on public.pomodoros;
create policy "pomodoros propios" on public.pomodoros for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
