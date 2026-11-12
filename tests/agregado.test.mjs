import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

const sql=await readFile(new URL('../supabase/install.sql',import.meta.url),'utf8');
const STAFF='40000000-0000-4000-8000-000000000001',CLIENTE='40000000-0000-4000-8000-000000000002',OUTRO='40000000-0000-4000-8000-000000000003';
const CONJUGE='41000000-0000-4000-8000-000000000002',FILHO='41000000-0000-4000-8000-000000000003';

test('remover um membro do agregado remove mesmo, e só quem pode',async()=>{
 const db=new PGlite();
 try{
  await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create schema storage;
  create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb not null default '{}',email_confirmed_at timestamptz default now(),deleted_at timestamptz,created_at timestamptz not null default now(),last_sign_in_at timestamptz);create table auth.mfa_factors(id uuid primary key default gen_random_uuid(),user_id uuid,status text,factor_type text);
  create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
  grant usage on schema auth,storage to authenticated;grant execute on function auth.uid() to authenticated;
  create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
  create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text not null,metadata jsonb);
  alter table storage.objects enable row level security;grant select,insert on storage.objects to authenticated;
  alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
  alter default privileges in schema public grant all on tables to anon, authenticated, service_role;`);
  await db.exec(sql);
  const meta=JSON.stringify({full_name:'Teste',birth_date:'1980-01-01',nif:'123456789',terms_accepted:true,terms_version:'2026-10-28.1',privacy_version:'2026-10-28.1'});
  for(const [id,email] of [[STAFF,'contabilidade.rubenrodrigues@gmail.com'],[CLIENTE,'cliente@example.com'],[OUTRO,'outro@example.com']])await db.query('insert into auth.users(id,email,raw_user_meta_data) values($1,$2,$3)',[id,email,meta]);
  await db.query('insert into public.staff_users(user_id) values($1) on conflict do nothing',[STAFF]);
  const como=async id=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
  const um=async(q,p=[])=>(await db.query(q,p)).rows[0];

  await como(STAFF);
  const conta=(await um('select public.approve_client($1,$2,2025) as id',[CLIENTE,'Cliente'])).id;
  await db.query('select public.approve_client($1,$2,2025)',[OUTRO,'Outro']);
  const processo=(await um('select id from public.irs_cases where account_id=$1 limit 1',[conta])).id;

  await como(CLIENTE);
  const guardar=(id,nome,nif,relacao)=>db.query('select public.guardar_membro_agregado($1,$2,$3,$4,null,$5,false,$6,$7)',[processo,nome,nif,relacao,'1985-05-05',id,'cifrada']);
  // O titular já vem do registo: é o próprio cliente.
  const titular=(await um("select person_id from public.case_people where case_id=$1 and relationship='titular'",[processo])).person_id;
  await guardar(CONJUGE,'Rui Cônjuge','222222222','conjuge');
  await guardar(FILHO,'Zé Filho','233333333','descendente');
  const membros=async()=>(await db.query('select person_id from public.case_people where case_id=$1',[processo])).rows.length;
  assert.equal(await membros(),3);

  // O titular fica; quem tem rendimentos também, até os tirar.
  await assert.rejects(db.query('select public.remover_membro_agregado($1,$2)',[processo,titular]),/titular/);
  await db.exec('reset role');
  await db.query("insert into public.income_records(account_id,case_id,category,person_id,title,mode) values($1,$2,'employment',$3,'Salário','manual')",[conta,processo,CONJUGE]);
  await como(CLIENTE);
  await assert.rejects(db.query('select public.remover_membro_agregado($1,$2)',[processo,CONJUGE]),/rendimentos/);

  // O rendimento: outra conta não o apaga (nem o vê); o próprio apaga.
  await como(OUTRO);
  assert.equal((await db.query('delete from public.income_records where case_id=$1 returning id',[processo])).rows.length,0);
  await como(CLIENTE);
  assert.equal((await db.query('delete from public.income_records where case_id=$1 returning id',[processo])).rows.length,1);
  await db.query('select public.remover_membro_agregado($1,$2)',[processo,CONJUGE]);
  assert.equal(await membros(),2);
  await db.query('select public.guardar_membro_agregado($1,$2,$3,$4,null,$5,false,$6,$7)',[processo,'Rui Cônjuge','222222222','conjuge','1985-05-05','41000000-0000-4000-8000-000000000009','cifrada']);
  await db.exec('reset role');
  const rendimento=(await um("insert into public.income_records(account_id,case_id,category,person_id,title,mode) values($1,$2,'employment',$3,'Salário','manual') returning id",[conta,processo,'41000000-0000-4000-8000-000000000009'])).id;

  // Outra conta não mexe neste processo.
  await como(OUTRO);
  await assert.rejects(db.query('select public.remover_membro_agregado($1,$2)',[processo,FILHO]),/não pode ser alterado/);

  // O próprio remove: a linha sai, e com ela a ficha e a senha de quem já não está em processo nenhum.
  await como(CLIENTE);
  await db.query('select public.remover_membro_agregado($1,$2)',[processo,FILHO]);
  assert.equal(await membros(),2);
  await db.exec('reset role');
  assert.equal((await um('select count(*)::int as n from public.people where id=$1',[FILHO])).n,0);
  assert.equal((await um('select count(*)::int as n from public.tax_credentials where person_id=$1',[FILHO])).n,0);
  assert.equal((await um('select count(*)::int as n from public.people where id=$1',[CONJUGE])).n,0,'o cônjuge removido antes também saiu');

  // Com o processo submetido, já não se altera o agregado nem os rendimentos.
  await db.query("update public.irs_cases set status='submitted_by_client' where id=$1",[processo]);
  await como(CLIENTE);
  await assert.rejects(db.query('select public.remover_membro_agregado($1,$2)',[processo,'41000000-0000-4000-8000-000000000009']),/não pode ser alterado/);
  assert.equal((await db.query('delete from public.income_records where id=$1 returning id',[rendimento])).rows.length,0,'o rendimento de um processo submetido fica');
  await assert.rejects(db.query('select public.remover_membro_agregado($1,$2)',[processo,'49000000-0000-4000-8000-000000000009']),/não pode ser alterado/);
 }finally{await db.close();}
});
