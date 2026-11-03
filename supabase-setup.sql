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
