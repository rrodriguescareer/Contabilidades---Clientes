import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {buildUpgradeSql} from '../scripts/build-install.mjs';
const upgrade=await readFile(new URL('../supabase/upgrade-005-007.sql',import.meta.url),'utf8');
test('published upgrade matches the new migration sources',async()=>assert.equal(upgrade,await buildUpgradeSql()));
test('upgrading the installed v1 preserves clients, originals, invoices and legal history',async()=>{
 const db=new PGlite();
 try{
  await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create schema storage;
  create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz default now(),raw_user_meta_data jsonb not null default '{}');
  create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
  grant usage on schema auth,storage to authenticated;grant execute on function auth.uid() to authenticated;
  create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
  create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text not null);
  alter table storage.objects enable row level security;grant select,insert on storage.objects to authenticated;`);
  for(const name of ['202610230001_core.sql','202610230002_legal_acceptances.sql','202610230003_production_legal_version.sql','202610230004_annual_cases.sql'])await db.exec(await readFile(new URL('../supabase/migrations/'+name,import.meta.url),'utf8'));
  const staff='40000000-0000-4000-8000-000000000001',client='40000000-0000-4000-8000-000000000002';
  for(const id of [staff,client])await db.query('insert into auth.users(id,email,raw_user_meta_data) values($1,$2,$3)',[id,id===staff?'contabilidade.rubenrodrigues@gmail.com':'existing@example.com',JSON.stringify({full_name:'Existing client',birth_date:'1980-01-01',nif:'123456789',terms_accepted:true,terms_version:'2026-10-23.2',privacy_version:'2026-10-23.2'})]);
  await db.query('insert into public.staff_users(user_id) values($1)',[staff]);await db.query("select set_config('request.jwt.claim.sub',$1,false)",[staff]);
  const account=(await db.query("select public.approve_client($1,'Existing account',2025) as id",[client])).rows[0].id;
  const process=(await db.query('select id from public.irs_cases where account_id=$1',[account])).rows[0].id,doc='40000000-0000-4000-8000-000000000003',path=`${account}/${process}/${doc}`;
  await db.query("insert into public.documents(id,account_id,case_id,kind,file_name,storage_path,mime_type,file_size,state) values($1,$2,$3,'Other','original.pdf',$4,'application/pdf',10,'uploaded')",[doc,account,process,path]);
  await db.query("insert into storage.objects(bucket_id,name) values('irs-documents',$1)",[path]);
  await db.query("insert into public.invoices(account_id,reference,issued_at,total) values($1,'FT-EXISTING','2026-10-23',100)",[account]);
  await db.exec(upgrade);
  assert.equal((await db.query('select name from public.client_accounts where id=$1',[account])).rows[0].name,'Existing account');
  assert.equal((await db.query('select storage_path from public.documents where id=$1',[doc])).rows[0].storage_path,path);
  assert.equal((await db.query('select name from storage.objects')).rows[0].name,path);
  assert.equal((await db.query('select reference from public.invoices')).rows[0].reference,'FT-EXISTING');
  assert.equal((await db.query('select terms_version from public.legal_acceptances where user_id=$1',[client])).rows[0].terms_version,'2026-10-23.2');
  assert.equal((await db.query('select public.is_staff() as staff')).rows[0].staff,true);
  await assert.rejects(db.exec(upgrade),/ja foi aplicada/);await db.exec('rollback');
  assert.equal((await db.query('select count(*)::int as n from public.documents')).rows[0].n,1);
 }finally{await db.close();}
});
