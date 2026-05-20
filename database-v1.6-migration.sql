-- =====================================================================
-- CRM GA — Migration v1.5 → v1.6
-- Run this in Supabase SQL Editor on top of an existing v1.5 database.
-- Safe to re-run (uses IF NOT EXISTS / ON CONFLICT where applicable).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1.  New columns on requests
-- ---------------------------------------------------------------------
alter table requests
  add column if not exists divisi         text,
  add column if not exists departemen     text,
  add column if not exists mata_anggaran  text;

create index if not exists idx_requests_divisi     on requests(divisi);
create index if not exists idx_requests_departemen on requests(departemen);

-- ---------------------------------------------------------------------
-- 2.  Mata Anggaran (master) — budget line items
-- ---------------------------------------------------------------------
create table if not exists mata_anggaran_options (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  kode        text,                                   -- optional accounting code
  description text,
  created_at  timestamptz default now()
);

alter table mata_anggaran_options enable row level security;
drop policy if exists p_mata_anggaran_all on mata_anggaran_options;
create policy p_mata_anggaran_all on mata_anggaran_options
  for all using (true) with check (true);

insert into mata_anggaran_options (name, kode, description) values
  ('Operasional Harian',          'OPS-001', 'Kebutuhan harian kantor (ATK, snack, dll).'),
  ('Event & Gathering',           'EVT-001', 'Pengeluaran terkait event, townhall, gathering.'),
  ('Perawatan Fasilitas',         'MNT-001', 'Perawatan & perbaikan fasilitas kantor.'),
  ('Pengadaan Seragam',           'UFM-001', 'Pengadaan seragam karyawan.'),
  ('Pengembangan SDM',            'HRD-001', 'Training, workshop, sertifikasi.'),
  ('Lain-lain',                   'OTH-001', 'Pengeluaran lain di luar kategori utama.')
on conflict (name) do nothing;

-- ---------------------------------------------------------------------
-- 3.  Divisi (master, parent of Departemen)
-- ---------------------------------------------------------------------
create table if not exists divisi_options (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  created_at  timestamptz default now()
);

alter table divisi_options enable row level security;
drop policy if exists p_divisi_all on divisi_options;
create policy p_divisi_all on divisi_options
  for all using (true) with check (true);

-- ---------------------------------------------------------------------
-- 4.  Departemen (master, FK → divisi_options)
-- ---------------------------------------------------------------------
create table if not exists departemen_options (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  divisi_id   uuid not null references divisi_options(id) on delete cascade,
  created_at  timestamptz default now(),
  unique(name, divisi_id)
);
create index if not exists idx_departemen_divisi on departemen_options(divisi_id);

alter table departemen_options enable row level security;
drop policy if exists p_departemen_all on departemen_options;
create policy p_departemen_all on departemen_options
  for all using (true) with check (true);

-- ---------------------------------------------------------------------
-- 5.  Seed sample Divisi + Departemen (skip if you already have data)
-- ---------------------------------------------------------------------
do $$
declare
  v_dir_ops    uuid;
  v_dir_corp   uuid;
  v_dir_eng    uuid;
  v_dir_fin    uuid;
begin
  -- Only seed if the divisi_options table is empty
  if not exists (select 1 from divisi_options) then
    insert into divisi_options (name) values
      ('Direktorat Operasi & Pemeliharaan')   returning id into v_dir_ops;
    insert into divisi_options (name) values
      ('Direktorat Corporate Services')       returning id into v_dir_corp;
    insert into divisi_options (name) values
      ('Direktorat Engineering & Konstruksi') returning id into v_dir_eng;
    insert into divisi_options (name) values
      ('Direktorat Keuangan & SDM')           returning id into v_dir_fin;

    insert into departemen_options (name, divisi_id) values
      ('Operasi Stasiun',           v_dir_ops),
      ('Operasi Kereta',            v_dir_ops),
      ('Pemeliharaan Sarana',       v_dir_ops),
      ('Pemeliharaan Prasarana',    v_dir_ops),

      ('General Affairs',           v_dir_corp),
      ('Legal & Compliance',        v_dir_corp),
      ('Procurement',               v_dir_corp),
      ('Corporate Communications',  v_dir_corp),

      ('Engineering',               v_dir_eng),
      ('Konstruksi',                v_dir_eng),
      ('Project Management',        v_dir_eng),

      ('Keuangan',                  v_dir_fin),
      ('Akuntansi',                 v_dir_fin),
      ('Human Capital',             v_dir_fin),
      ('IT & Sistem',               v_dir_fin);
  end if;
end$$;

-- ---------------------------------------------------------------------
-- 6.  Version history entry
-- ---------------------------------------------------------------------
insert into version_history (version, release_date, changes) values
  ('1.6.0', '2026-05-18',
   'Tracking by SmartOffice code, dashboard screenshot JPG, kolom Mata Anggaran (+master), kolom Divisi & Departemen (+master dengan cascading dropdown), tombol Backup Data XLSX multi-sheet.')
on conflict do nothing;

-- =====================================================================
-- DONE. Hard refresh the portal (Ctrl+Shift+R) after running this.
-- =====================================================================
