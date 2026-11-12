import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir,access} from 'node:fs/promises';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {PGlite} from '@electric-sql/pglite';

/* Cada chamada à base de dados feita pelas três aplicações tem de existir e de
   ter a permissão de que precisa, com os privilégios por omissão do Supabase.
   Foi assim que escaparam os botões «Remover» do portal IRS: a função e a
   tabela existiam, a permissão não, e o cliente via um erro em inglês. */

const raiz=fileURLToPath(new URL('../..',import.meta.url));
const APPS=['irs-2026','gestao-clientes','empresas'];
const existe=async p=>access(p).then(()=>true,()=>false);
async function* fontes(d){
 for(const e of await readdir(d,{withFileTypes:true})){
  if(['node_modules','.next','tests','.git','scripts'].includes(e.name))continue;
  const p=join(d,e.name);
  if(e.isDirectory())yield* fontes(p);else if(/\.tsx?$/.test(e.name))yield p;
 }
}

test('todas as chamadas à base existem e têm permissão',async t=>{
 for(const app of APPS)if(!(await existe(join(raiz,app)))){t.skip(`sem a pasta ${app} ao lado`);return;}
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
  await db.exec(await readFile(join(raiz,'gestao-clientes/supabase/install.sql'),'utf8'));

  const funcoes=new Map(),tabelas=new Map();
  for(const r of (await db.query(`select p.proname n,bool_or(has_function_privilege('authenticated',p.oid,'execute')) a,bool_or(has_function_privilege('service_role',p.oid,'execute')) s,bool_or(has_function_privilege('anon',p.oid,'execute')) anon from pg_proc p where p.pronamespace='public'::regnamespace group by 1`)).rows)funcoes.set(r.n,r);
  for(const r of (await db.query(`select c.relname n,has_any_column_privilege('authenticated',c.oid,'select') sel,has_any_column_privilege('authenticated',c.oid,'insert') ins,has_any_column_privilege('authenticated',c.oid,'update') upd,has_table_privilege('authenticated',c.oid,'delete') del,has_table_privilege('anon',c.oid,'select') anon from pg_class c where c.relnamespace='public'::regnamespace and c.relkind in ('r','v')`)).rows)tabelas.set(r.n,r);

  const falhas=[];
  for(const app of APPS)for await(const p of fontes(join(raiz,app))){
   const s=await readFile(p,'utf8'),onde=p.slice(raiz.length);
   for(const m of s.matchAll(/([\w.()]+)\s*\.rpc\(\s*'(\w+)'/g)){
    const f=funcoes.get(m[2]);
    if(!f){falhas.push(`${onde}: a função ${m[2]} não existe`);continue;}
    const quem=/admin/i.test(m[1])?'s':'a';
    if(!f[quem])falhas.push(`${onde}: ${m[2]} é chamada ${quem==='a'?'com a sessão do utilizador':'pelo servidor'} sem permissão`);
   }
   for(const m of s.matchAll(/([\w.()]+)\s*\.from\(\s*'(\w+)'\s*\)((?:\s*\.\w+\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))+)/g)){
    if(/storage/i.test(m[1]))continue;
    const tb=tabelas.get(m[2]);
    if(!tb){falhas.push(`${onde}: a tabela ${m[2]} não existe`);continue;}
    if(/admin/i.test(m[1]))continue;
    const op=/\.insert\(|\.upsert\(/.test(m[3])?'ins':/\.update\(/.test(m[3])?'upd':/\.delete\(/.test(m[3])?'del':'sel';
    if(!tb[op])falhas.push(`${onde}: ${m[2]} — ${({ins:'inserir',upd:'alterar',del:'apagar',sel:'ler'})[op]} com a sessão do utilizador, sem permissão`);
   }
  }
  assert.deepEqual(falhas,[]);
  assert.deepEqual([...funcoes.values()].filter(x=>x.anon).map(x=>x.n),[],'nenhuma função para quem não tem sessão');
  assert.deepEqual([...tabelas.values()].filter(x=>x.anon).map(x=>x.n),['avisos'],'sem sessão, só os avisos');
 }finally{await db.close();}
});
