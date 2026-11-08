import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

const sql=await readFile(new URL('../supabase/install.sql',import.meta.url),'utf8');
const STAFF='30000000-0000-4000-8000-000000000001',CLIENTE='30000000-0000-4000-8000-000000000002';

async function preparar(){
 const db=new PGlite();
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create schema storage;
 create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb not null default '{}',email_confirmed_at timestamptz default now(),deleted_at timestamptz,created_at timestamptz not null default now(),last_sign_in_at timestamptz);create table auth.mfa_factors(id uuid primary key default gen_random_uuid(),user_id uuid,status text,factor_type text);
 create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
 grant usage on schema auth,storage to authenticated;grant execute on function auth.uid() to authenticated;
 create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text not null,metadata jsonb);
 alter table storage.objects enable row level security;grant select,insert on storage.objects to authenticated;`);
 await db.exec(sql);
 for(const id of [STAFF,CLIENTE])await db.query('insert into auth.users(id,email,raw_user_meta_data) values($1,$2,$3)',[id,id===STAFF?'contabilidade.rubenrodrigues@gmail.com':'cliente@example.com',JSON.stringify({full_name:'Teste',birth_date:'1980-01-01',nif:'123456789',terms_accepted:true,terms_version:'2026-10-28.1',privacy_version:'2026-10-28.1'})]);
 await db.query('insert into public.staff_users(user_id) values($1) on conflict do nothing',[STAFF]);
 const empresa=(await db.query(`insert into public.companies(name,nif) values('Empresa Teste','501234567') returning id`)).rows[0].id;
 return {db,empresa};
}
const como=async(db,id)=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
const servidor=async db=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub','',false)");};
const um=async(db,q,p=[])=>(await db.query(q,p)).rows[0];

test('cadência: dias corridos, úteis e da semana, na hora de Lisboa',async()=>{
 const {db}=await preparar();
 try{
  const p=async(c,d)=>(await um(db,"select to_char(public.secretaria_proximo_envio($1::jsonb,$2::timestamptz) at time zone 'Europe/Lisbon','YYYY-MM-DD HH24:MI') as v",[c,d])).v;
  assert.equal(await p('{"modo":"corridos","intervalo":7,"hora":9}','2026-11-02T10:00:00Z'),'2026-11-09 09:00');
  assert.equal(await p('{"modo":"uteis","intervalo":2,"hora":14}','2026-11-06T10:00:00Z'),'2026-11-10 14:00');
  assert.equal(await p('{"modo":"semana","dias":{"1":9,"4":15}}','2026-11-02T10:00:00Z'),'2026-11-05 15:00');
  assert.equal(await p('{"modo":"semana","dias":{"1":9}}','2026-11-02T08:00:00Z'),'2026-11-02 09:00');
 }finally{await db.close();}
});

test('um processo do início ao fim: aprovação, insistência, entrega e auditoria',async()=>{
 const {db,empresa}=await preparar();
 try{
  await como(db,STAFF);
  const pend=[];
  for(const [d,n] of [['Fornecedor A','FT 1/1'],['Fornecedor B','FT 2/1']])
   pend.push((await um(db,"insert into public.secretaria_pendencias(company_id,periodo,descricao,numero,data_documento) values($1,'2026-10-01',$2,$3,'2026-10-15') returning id",[empresa,d,n])).id);
  const limite='2030-12-10';
  await assert.rejects(db.query('select public.secretaria_iniciar_processo($1,$2,true)',[empresa,limite]),/contacto principal/);
  await db.query("insert into public.secretaria_contactos(company_id,nome,email,principal) values($1,'Ana','ana@example.com',true)",[empresa]);
  const inicio=(await um(db,'select public.secretaria_iniciar_processo($1,$2,true) as r',[empresa,limite])).r;
  assert.equal(inicio.estado,'por_aprovar');
  await assert.rejects(db.query('select public.secretaria_iniciar_processo($1,$2,true)',[empresa,limite]),/processo em curso/);

  assert.equal((await um(db,'select public.contagens_do_gabinete() as c')).c.secretaria_aprovar,1);
  await servidor(db);
  assert.deepEqual((await um(db,'select public.secretaria_tarefas() as r')).r.a_enviar,[],'nada sai sem aprovação');

  await como(db,STAFF);
  await db.query('select public.secretaria_decidir_envio($1,true,null,null)',[inicio.envio]);
  await assert.rejects(db.query('select public.secretaria_decidir_envio($1,true,null,null)',[inicio.envio]),/já foi decidido/);
  await servidor(db);
  assert.deepEqual((await um(db,'select public.secretaria_tarefas() as r')).r.a_enviar,[inicio.envio]);
  const dados=(await um(db,'select public.secretaria_reservar_envio($1) as r',[inicio.envio])).r;
  assert.equal(dados.pendencias.length,2);
  assert.equal((await um(db,'select public.secretaria_reservar_envio($1) as r',[inicio.envio])).r,null,'não sai duas vezes');
  await db.query("select public.secretaria_envio_resultado($1,true,'ana@example.com','{}','hash-do-token',null)",[inicio.envio]);
  const proc=await um(db,"select * from public.secretaria_processos where company_id=$1",[empresa]);
  assert.ok(proc.proximo_envio,'fica agendada a insistência');
  assert.ok(proc.primeiro_contacto);

  // A hora da insistência: sem aprovação (só o primeiro email a pede).
  await db.query("update public.secretaria_processos set proximo_envio=now()-interval '1 hour' where id=$1",[proc.id]);
  const hora=(await um(db,'select public.secretaria_tarefas() as r')).r;
  assert.equal(hora.a_enviar.length,1);
  assert.equal((await um(db,'select tipo from public.secretaria_envios where id=$1',[hora.a_enviar[0]])).tipo,'insistencia');
  assert.ok((await um(db,'select proximo_envio from public.secretaria_processos where id=$1',[proc.id])).proximo_envio>new Date());

  // A ligação do email mostra o que falta.
  let e=(await um(db,"select public.secretaria_entrega('hash-do-token') as r")).r;
  assert.equal(e.estado,'aberto');assert.equal(e.pendencias.length,2);
  assert.equal((await um(db,"select public.secretaria_entrega('outro') as r")).r.estado,'invalido');

  const entregar=async p=>{
   const d=(await um(db,"select public.secretaria_doc_registar($1,$2,'fatura.pdf','application/pdf',1000,null,null) as r",[empresa,p])).r;
   await assert.rejects(db.query("select public.secretaria_doc_concluir($1,'Cliente')",[d.id]),/ainda não chegou/);
   await db.query("insert into storage.buckets(id,name,public) values('empresas-documentos','x',false) on conflict do nothing");
   await db.query("insert into storage.objects(bucket_id,name,metadata) values('empresas-documentos',$1,'{\"size\":1000,\"mimetype\":\"application/pdf\"}')",[d.caminho]);
   return (await um(db,"select public.secretaria_doc_concluir($1,'Cliente') as r",[d.id])).r;
  };
  assert.equal((await entregar(pend[0])).associado,true);
  await assert.rejects(db.query("select public.secretaria_doc_registar($1,$2,'outra.pdf','application/pdf',1000,null,null)",[empresa,pend[0]]),/já não está em falta/);
  assert.equal((await um(db,'select count(*)::int as n from public.secretaria_processos where estado=$1',['em_curso'])).n,1,'ainda falta um');
  const fim=await entregar(pend[1]);
  assert.equal(fim.terminou,true);
  const p2=await um(db,'select estado,motivo,ultima_resposta from public.secretaria_processos where id=$1',[proc.id]);
  assert.equal(p2.motivo,'nada_falta');assert.ok(p2.ultima_resposta);
  assert.equal((await um(db,"select public.secretaria_entrega('hash-do-token') as r")).r.estado,'terminado');

  // Um documento sem pendência vai para «Por identificar».
  const solto=(await um(db,"select public.secretaria_doc_registar($1,null,'solto.pdf','application/pdf',1000,null,null) as r",[empresa])).r;
  await db.query("insert into storage.objects(bucket_id,name,metadata) values('empresas-documentos',$1,'{\"size\":1000,\"mimetype\":\"application/pdf\"}')",[solto.caminho]);
  assert.equal((await um(db,"select public.secretaria_doc_concluir($1,'Cliente') as r",[solto.id])).r.associado,false);
  assert.equal((await um(db,"select estado from public.secretaria_por_identificar where documento_id=$1",[solto.id])).estado,'por_rever');

  await como(db,STAFF);
  const painel=(await um(db,'select public.secretaria_painel() as r')).r;
  assert.equal(painel.recebidos,2);assert.equal(painel.em_falta,0);assert.equal(painel.por_identificar,1);
  const clientes=(await um(db,"select public.secretaria_clientes_resumo('2026-10-01','2026-10-01') as r")).r;
  assert.equal(clientes[0].recebidas,2);assert.equal(clientes[0].resposta,'respondeu');

  const v=(await um(db,'select public.secretaria_auditoria_verificar() as r')).r;
  assert.equal(v.valida,true);assert.ok(v.eventos>=6);
  await db.exec('reset role');
  await assert.rejects(db.query("update public.secretaria_auditoria set detalhe='x'"),/não pode ser alterada/);
 }finally{await db.close();}
});

test('pendências: ações em bloco, fecho automático e rejeição do primeiro pedido',async()=>{
 const {db,empresa}=await preparar();
 try{
  await como(db,STAFF);
  await db.query("insert into public.secretaria_contactos(company_id,nome,email,principal) values($1,'Ana','ana@example.com',true)",[empresa]);
  const nova=async()=> (await um(db,"insert into public.secretaria_pendencias(company_id,periodo,descricao) values($1,'2026-10-01','Extrato') returning id",[empresa])).id;
  const a=await nova();
  let r=(await um(db,'select public.secretaria_iniciar_processo($1,$2,true) as r',[empresa,'2030-01-01'])).r;
  await db.query('select public.secretaria_decidir_envio($1,false,null,null)',[r.envio]);
  assert.equal((await um(db,'select motivo from public.secretaria_processos where id=$1',[r.id])).motivo,'cancelado','rejeitar o primeiro cancela');

  r=(await um(db,'select public.secretaria_iniciar_processo($1,$2,true) as r',[empresa,'2030-01-01'])).r;
  await db.query("select public.secretaria_pendencias_acao($1,'recebida')",[[a]]);
  const p=await um(db,'select estado,motivo from public.secretaria_processos where id=$1',[r.id]);
  assert.equal(p.estado,'terminado');assert.equal(p.motivo,'nada_falta');
  assert.equal((await um(db,'select estado from public.secretaria_envios where id=$1',[r.envio])).estado,'rejeitado','o que estava por aprovar já não sai');

  await db.query("select public.secretaria_pendencias_acao($1,'reabrir')",[[a]]);
  assert.equal((await um(db,'select estado from public.secretaria_pendencias where id=$1',[a])).estado,'pendente');
  await assert.rejects(db.query('select public.secretaria_pendencias_acao($1,$2)',[[a],'apagar']),/Ação inválida/);
 }finally{await db.close();}
});

test('as permissões: nada para quem não tem sessão, o servidor só no servidor, um cliente fora',async()=>{
 const {db,empresa}=await preparar();
 try{
  assert.equal((await um(db,"select count(*)::int as n from pg_proc p where p.pronamespace='public'::regnamespace and (p.proname like 'secretaria\\_%' or p.proname='portal_pendencias') and has_function_privilege('anon',p.oid,'execute')")).n,0);
  const so=(await db.query("select p.proname from pg_proc p where p.pronamespace='public'::regnamespace and p.proname like 'secretaria\\_%' and has_function_privilege('authenticated',p.oid,'execute') order by 1")).rows.map(x=>x.proname);
  for(const f of ['secretaria_tarefas','secretaria_reservar_envio','secretaria_envio_resultado','secretaria_entrega','secretaria_doc_registar','secretaria_doc_concluir','secretaria_registar','secretaria_chave_valida'])assert.ok(!so.includes(f),f);
  assert.deepEqual((await db.query("select tablename from pg_tables where schemaname='public' and tablename like 'secretaria\\_%' and not rowsecurity")).rows,[]);
  await como(db,CLIENTE);
  await assert.rejects(db.query('select public.secretaria_painel()'),/Sem acesso/);
  await assert.rejects(db.query('select public.secretaria_iniciar_processo($1,$2,true)',[empresa,'2030-01-01']),/Sem acesso/);
  await assert.rejects(db.query('select public.portal_pendencias($1)',[empresa]),/Sem acesso/);
  assert.equal((await um(db,'select count(*)::int as n from public.secretaria_contactos')).n,0);
 }finally{await db.close();}
});
