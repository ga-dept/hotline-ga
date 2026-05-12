-- =====================================================================
-- GA HOTLINE PORTAL - DATABASE SCHEMA
-- PostgreSQL / Supabase
-- =====================================================================
-- Run this entire file in the Supabase SQL Editor.
-- Order of execution: extensions -> tables -> functions -> triggers
-- -> RLS policies -> seed data -> storage bucket.
-- =====================================================================

-- ---------- EXTENSIONS -----------------------------------------------
create extension if not exists "pgcrypto";   -- gen_random_uuid(), crypt()

-- ---------- DROP (idempotent re-runs) --------------------------------
drop view  if exists v_request_summary cascade;
drop table if exists ratings           cascade;
drop table if exists requests          cascade;
drop table if exists app_users         cascade;
drop table if exists lokasi_options    cascade;
drop table if exists tujuan_options    cascade;
drop table if exists version_history   cascade;
drop table if exists counters          cascade;

-- ---------- TABLES ---------------------------------------------------

-- Lookup: locations (editable from Admin)
create table lokasi_options (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  created_at timestamptz default now()
);

-- Lookup: purposes (editable from Admin)
create table tujuan_options (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  created_at timestamptz default now()
);

-- App users (admins / PIC GA) - separate from Supabase auth for simplicity
create table app_users (
  id            uuid primary key default gen_random_uuid(),
  username      text not null unique,
  password_hash text not null,
  full_name     text not null,
  role          text not null check (role in ('superadmin','admin','pic')) default 'admin',
  active        boolean default true,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

-- Daily counter for request code generation (DDMMYYYY####)
create table counters (
  day_key    text primary key,   -- e.g. '12052026'
  last_seq   integer not null default 0,
  updated_at timestamptz default now()
);

-- Main requests table
create table requests (
  id                     uuid primary key default gen_random_uuid(),
  kode_permintaan        text not null unique,   -- e.g. FB-120520260001
  kode_smartoffice       text,                   -- manual entry for FB/EV/OS/DP

  kategori               text not null check (kategori in (
                            'Food and Beverage',
                            'Direct Purchase',
                            'Fasilitas Kantor dan Identitas Karyawan',
                            'Seragam',
                            'Office Supply',
                            'Event Support')),
  kategori_kode          text not null,          -- FB / DP / FAC / UFM / OS / EV

  sumber_pemesanan       text not null,          -- WhatsApp / SmartOffice / Walk-in / dst
  nama_pemesan           text not null,
  nama_kegiatan          text,
  lokasi_kebutuhan       text,
  tujuan_kebutuhan       text,
  tanggal_kebutuhan      date not null,
  detail_kebutuhan       text not null,
  estimasi_harga         bigint default 0,       -- rupiah
  lampiran_url           text,                   -- storage URL

  -- Admin-managed fields
  status                 text not null default 'Belum Dikonfirmasi'
                          check (status in (
                            'Belum Dikonfirmasi',
                            'Mencari Penyedia',
                            'Sedang Disiapkan',
                            'Tersedia',
                            'Selesai',
                            'Ditolak')),
  keterangan             text,
  total_anggaran         bigint default 0,
  nama_vendor            text,
  nama_pic_ga            text,
  estimasi_penyelesaian  date,

  created_at             timestamptz default now(),
  updated_at             timestamptz default now()
);

create index idx_requests_kategori  on requests(kategori);
create index idx_requests_status    on requests(status);
create index idx_requests_created   on requests(created_at desc);
create index idx_requests_kode      on requests(kode_permintaan);

-- Ratings table (1 rating per request)
create table ratings (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null references requests(id) on delete cascade,
  rating        integer not null check (rating between 1 and 5),
  kritik_saran  text,
  created_at    timestamptz default now(),
  unique(request_id)
);

create index idx_ratings_request on ratings(request_id);

-- Version history
create table version_history (
  id           uuid primary key default gen_random_uuid(),
  version      text not null,
  release_date date not null,
  changes      text not null,
  created_at   timestamptz default now()
);

-- ---------- FUNCTIONS / TRIGGERS -------------------------------------

-- updated_at auto-touch
create or replace function fn_touch_updated_at() returns trigger as $$
begin
  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

create trigger trg_requests_updated   before update on requests
  for each row execute function fn_touch_updated_at();
create trigger trg_app_users_updated  before update on app_users
  for each row execute function fn_touch_updated_at();

-- Generate next request code: <PREFIX>-DDMMYYYY####
-- Atomically increments a per-day counter.
create or replace function fn_generate_request_code(p_prefix text)
returns text as $$
declare
  v_day_key text := to_char(now() at time zone 'Asia/Jakarta', 'DDMMYYYY');
  v_seq     int;
begin
  insert into counters(day_key, last_seq)
       values (v_day_key, 1)
  on conflict (day_key) do update
       set last_seq = counters.last_seq + 1,
           updated_at = now()
  returning last_seq into v_seq;

  return p_prefix || '-' || v_day_key || lpad(v_seq::text, 4, '0');
end;
$$ language plpgsql;

-- Public-safe view used by landing-page tracker (hides sensitive admin fields
-- that some teams may consider internal; keep what user needs to see).
create or replace view v_request_summary as
select
  id,
  kode_permintaan,
  kategori,
  nama_pemesan,
  nama_kegiatan,
  tanggal_kebutuhan,
  status,
  keterangan,
  nama_pic_ga,
  estimasi_penyelesaian,
  created_at
from requests;

-- ---------- ROW LEVEL SECURITY ---------------------------------------
-- Keep things simple and demo-friendly:
--  * Public can SELECT requests (needed for tracker) and INSERT requests
--    (needed for the public form).
--  * Public can SELECT/INSERT ratings (needed for the rating link page).
--  * Updates/deletes and user table changes happen from the Admin UI
--    while RLS is permissive; production deployments should swap to a
--    Supabase service role + Edge Function for admin mutations.
-- ---------------------------------------------------------------------
alter table requests        enable row level security;
alter table ratings         enable row level security;
alter table app_users       enable row level security;
alter table lokasi_options  enable row level security;
alter table tujuan_options  enable row level security;
alter table version_history enable row level security;
alter table counters        enable row level security;

-- Permissive policies for the anon role (demo / internal portal scope).
create policy p_requests_all        on requests        for all using (true) with check (true);
create policy p_ratings_all         on ratings         for all using (true) with check (true);
create policy p_app_users_all       on app_users       for all using (true) with check (true);
create policy p_lokasi_all          on lokasi_options  for all using (true) with check (true);
create policy p_tujuan_all          on tujuan_options  for all using (true) with check (true);
create policy p_version_all         on version_history for all using (true) with check (true);
create policy p_counters_all        on counters        for all using (true) with check (true);

-- Login helper: returns user row if credentials match (bcrypt compare).
create or replace function fn_login(p_user text, p_pass text)
returns table(id uuid, username text, full_name text, role text) as $$
  select id, username, full_name, role
    from app_users
   where username = p_user
     and active = true
     and password_hash = crypt(p_pass, password_hash)
   limit 1;
$$ language sql security definer;

-- Create user with bcrypt-hashed password.
create or replace function fn_create_user(
  p_username text, p_password text, p_full_name text, p_role text)
returns app_users as $$
declare v_row app_users;
begin
  insert into app_users(username, password_hash, full_name, role)
       values (p_username, crypt(p_password, gen_salt('bf')), p_full_name, p_role)
    returning * into v_row;
  return v_row;
end;
$$ language plpgsql security definer;

-- Update a user's password (rehashes with bcrypt).
create or replace function fn_set_password(p_user_id uuid, p_password text)
returns void as $$
  update app_users
     set password_hash = crypt(p_password, gen_salt('bf')),
         updated_at = now()
   where id = p_user_id;
$$ language sql security definer;

-- Allow anon role to call these helpers
grant execute on function fn_login(text, text)            to anon, authenticated;
grant execute on function fn_create_user(text, text, text, text) to anon, authenticated;
grant execute on function fn_set_password(uuid, text)     to anon, authenticated;
grant execute on function fn_generate_request_code(text)  to anon, authenticated;

-- ---------- SEED DATA ------------------------------------------------

-- Default admin user (username: admin / password: admin123)
-- Password is stored as bcrypt hash via pgcrypto.
insert into app_users (username, password_hash, full_name, role)
values
  ('admin',     crypt('admin123', gen_salt('bf')), 'Super Admin',     'superadmin'),
  ('ga.budi',   crypt('budi123',  gen_salt('bf')), 'Budi Santoso',    'admin'),
  ('ga.siti',   crypt('siti123',  gen_salt('bf')), 'Siti Nurhaliza',  'pic');

-- Locations
insert into lokasi_options (name) values
  ('Lantai 1 - Lobby Utama'),
  ('Lantai 5 - Meeting Room A'),
  ('Lantai 5 - Meeting Room B'),
  ('Lantai 7 - Ruang Direksi'),
  ('Lantai 10 - Open Space'),
  ('Lantai 12 - Pantry'),
  ('Depo Lebak Bulus'),
  ('Depo Velodrome'),
  ('Stasiun Bundaran HI');

-- Purposes
insert into tujuan_options (name) values
  ('Rapat Internal'),
  ('Rapat dengan Vendor'),
  ('Rapat dengan Stakeholder Eksternal'),
  ('Training / Workshop'),
  ('Townhall / Gathering'),
  ('Operasional Harian'),
  ('Event Khusus'),
  ('Kebutuhan Karyawan Baru');

-- Version history
insert into version_history (version, release_date, changes) values
  ('1.0.0', '2026-05-01', 'Rilis pertama portal GA Hotline: input permintaan, tracking publik, dashboard admin.'),
  ('1.1.0', '2026-05-08', 'Tambah fitur penilaian kepuasan via tautan & halaman Daftar Penilaian.'),
  ('1.2.0', '2026-05-12', 'Manajemen master data lokasi & tujuan, ekspor CSV, role-based user management.');

-- Sample requests (so the dashboard is not empty on first run)
do $$
declare
  v_code text;
begin
  v_code := fn_generate_request_code('FB');
  insert into requests (kode_permintaan, kategori, kategori_kode, sumber_pemesanan,
                        nama_pemesan, nama_kegiatan, lokasi_kebutuhan, tujuan_kebutuhan,
                        tanggal_kebutuhan, detail_kebutuhan, estimasi_harga,
                        kode_smartoffice, status)
  values (v_code, 'Food and Beverage', 'FB', 'WhatsApp',
          'Rina Wulandari', 'Rapat Bulanan Divisi Operasional',
          'Lantai 5 - Meeting Room A', 'Rapat Internal',
          current_date + 2, 'Snack box untuk 20 orang + air mineral', 1500000,
          'SO-FB-2026-0091', 'Mencari Penyedia');

  v_code := fn_generate_request_code('OS');
  insert into requests (kode_permintaan, kategori, kategori_kode, sumber_pemesanan,
                        nama_pemesan, nama_kegiatan, lokasi_kebutuhan, tujuan_kebutuhan,
                        tanggal_kebutuhan, detail_kebutuhan, estimasi_harga,
                        kode_smartoffice, status)
  values (v_code, 'Office Supply', 'OS', 'SmartOffice',
          'Andi Pratama', 'Restock ATK Lantai 10',
          'Lantai 10 - Open Space', 'Operasional Harian',
          current_date + 5, 'Kertas A4 5 rim, pulpen 2 box, sticky notes 10 pack', 750000,
          'SO-OS-2026-0118', 'Sedang Disiapkan');

  v_code := fn_generate_request_code('UFM');
  insert into requests (kode_permintaan, kategori, kategori_kode, sumber_pemesanan,
                        nama_pemesan, nama_kegiatan, lokasi_kebutuhan, tujuan_kebutuhan,
                        tanggal_kebutuhan, detail_kebutuhan, estimasi_harga, status,
                        total_anggaran, nama_vendor, nama_pic_ga, estimasi_penyelesaian,
                        keterangan)
  values (v_code, 'Seragam', 'UFM', 'WhatsApp',
          'Dewi Lestari', 'Pengadaan Seragam Karyawan Baru Batch Mei',
          'Lantai 7 - Ruang Direksi', 'Kebutuhan Karyawan Baru',
          current_date + 14, 'Seragam kerja size S/M/L untuk 12 karyawan baru', 8400000,
          'Selesai', 8200000, 'PT Garmen Sejahtera', 'Budi Santoso',
          current_date - 1, 'Seragam sudah diterima lengkap di Lt.7.');

  v_code := fn_generate_request_code('EV');
  insert into requests (kode_permintaan, kategori, kategori_kode, sumber_pemesanan,
                        nama_pemesan, nama_kegiatan, lokasi_kebutuhan, tujuan_kebutuhan,
                        tanggal_kebutuhan, detail_kebutuhan, estimasi_harga,
                        kode_smartoffice, status, total_anggaran, nama_vendor, nama_pic_ga)
  values (v_code, 'Event Support', 'EV', 'SmartOffice',
          'Hendra Wijaya', 'Townhall Q2 2026',
          'Lantai 1 - Lobby Utama', 'Townhall / Gathering',
          current_date + 21, 'Panggung, sound system, dekorasi, snack 200 pax', 35000000,
          'SO-EV-2026-0021', 'Belum Dikonfirmasi', 0, null, null);

  v_code := fn_generate_request_code('DP');
  insert into requests (kode_permintaan, kategori, kategori_kode, sumber_pemesanan,
                        nama_pemesan, lokasi_kebutuhan, tujuan_kebutuhan,
                        tanggal_kebutuhan, detail_kebutuhan, estimasi_harga,
                        kode_smartoffice, status)
  values (v_code, 'Direct Purchase', 'DP', 'WhatsApp',
          'Maya Sari', 'Lantai 12 - Pantry', 'Operasional Harian',
          current_date + 1, 'Pembelian galon air + dispenser pantry', 1200000,
          'SO-DP-2026-0307', 'Tersedia');

  v_code := fn_generate_request_code('FAC');
  insert into requests (kode_permintaan, kategori, kategori_kode, sumber_pemesanan,
                        nama_pemesan, lokasi_kebutuhan, tujuan_kebutuhan,
                        tanggal_kebutuhan, detail_kebutuhan, estimasi_harga, status,
                        keterangan)
  values (v_code, 'Fasilitas Kantor dan Identitas Karyawan', 'FAC', 'WhatsApp',
          'Reza Firmansyah', 'Lantai 7 - Ruang Direksi', 'Kebutuhan Karyawan Baru',
          current_date + 7, 'Cetak ID card untuk 5 karyawan baru', 250000,
          'Ditolak', 'Permintaan duplikat dengan permintaan sebelumnya.');
end $$;

-- Sample rating for the completed request
insert into ratings (request_id, rating, kritik_saran)
select id, 5, 'Pelayanan sangat cepat dan vendor sangat kooperatif. Terima kasih!'
from requests where status = 'Selesai' limit 1;

-- ---------- STORAGE BUCKET (for attachments) -------------------------
-- Run separately in Supabase Dashboard > Storage if bucket doesn't exist:
--   bucket name : ga-attachments
--   public      : true
-- Then this policy makes uploads work from anon clients:
insert into storage.buckets (id, name, public)
values ('ga-attachments', 'ga-attachments', true)
on conflict (id) do nothing;

drop policy if exists "public upload"   on storage.objects;
drop policy if exists "public read"     on storage.objects;
create policy "public upload" on storage.objects for insert
  with check (bucket_id = 'ga-attachments');
create policy "public read"   on storage.objects for select
  using (bucket_id = 'ga-attachments');

-- =====================================================================
-- DONE. Default admin credential:
--   username : admin
--   password : admin123
-- (Change immediately after first login from the User Management page.)
-- =====================================================================
