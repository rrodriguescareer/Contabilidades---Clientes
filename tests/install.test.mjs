import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {buildInstallSql} from '../scripts/build-install.mjs';

async function fixture(){
 const db=new PGlite();
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create schema storage;
 create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb not null default '{}',email_confirmed_at timestamptz default now(),deleted_at timestamptz);
 create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
 grant usage on schema auth,storage to authenticated;grant execute on function auth.uid() to authenticated;
 create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text not null);
 alter table storage.objects enable row level security;grant select,insert on storage.objects to authenticated;`);
 return db;
}
const sql=await readFile(new URL('../supabase/install.sql',import.meta.url),'utf8');
test('published installation contains the current migrations',async()=>assert.equal(sql,await buildInstallSql()));
test('one initial installation creates the complete schema and supports approval',async()=>{
 const db=await fixture();
 try{
  await db.exec(sql);
  assert.equal((await db.query("select count(*)::int as n from pg_tables where schemaname='public'")).rows[0].n,33);
  assert.deepEqual((await db.query("select tablename from pg_tables where schemaname='public' and not rowsecurity")).rows,[]);
  assert.equal((await db.query("select public from storage.buckets where id='irs-documents'")).rows[0].public,false);
  const staff='20000000-0000-4000-8000-000000000001',client='20000000-0000-4000-8000-000000000002';
  for(const id of [staff,client])await db.query('insert into auth.users(id,email,raw_user_meta_data) values($1,$2,$3)',[id,(id===staff?'contabilidade.rubenrodrigues@gmail.com':id+'@example.com'),JSON.stringify({full_name:'Installation check',birth_date:'1980-01-01',nif:'123456789',terms_accepted:true,terms_version:'2026-10-23.3',privacy_version:'2026-10-23.3'})]);
  await db.query('insert into public.staff_users(user_id) values($1) on conflict do nothing',[staff]);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[staff]);
  await db.exec('set role authenticated');
  const account=(await db.query('select public.approve_client($1,$2,2025) as id',[client,'Client'])).rows[0].id;
  assert.equal((await db.query('select public.approve_client($1,$2,2025) as id',[client,'Client'])).rows[0].id,account);
  await db.query('select public.create_irs_case($1,2026)',[account]);
  assert.equal((await db.query('select count(*)::int as n from public.irs_cases')).rows[0].n,2);
  assert.equal((await db.query('select terms_version from public.legal_acceptances where user_id=$1',[client])).rows[0].terms_version,'2026-10-23.3');
  await db.exec('reset role');
  await assert.rejects(db.exec(sql),/Ja existe public\./);
  await db.exec('rollback');
  assert.equal((await db.query('select count(*)::int as n from public.irs_cases')).rows[0].n,2);
 }finally{await db.close();}
});
test('a partially existing schema is left untouched',async()=>{
 const db=await fixture();
 try{
  await db.exec('create table public.irs_cases(id integer primary key);insert into public.irs_cases values(42);');
  await assert.rejects(db.exec(sql),/Ja existe public\.irs_cases/);
  await db.exec('rollback');
  assert.equal((await db.query('select id from public.irs_cases')).rows[0].id,42);
  assert.equal((await db.query("select to_regclass('public.profiles') as relation")).rows[0].relation,null);
 }finally{await db.close();}
});
