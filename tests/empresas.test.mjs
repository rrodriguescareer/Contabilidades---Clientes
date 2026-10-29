import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// O portal Clientes Empresa: acesso por empresa, data de corte, documentos do
// mês, mensagens e prazos. PostgreSQL local; nunca contacta o Supabase.
const ids={staff:'40000000-0000-4000-8000-000000000001',a:'40000000-0000-4000-8000-000000000002',b:'40000000-0000-4000-8000-000000000003'};
test('portal Clientes Empresa',async t=>{
 const db=new PGlite();
 try{
  await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create schema storage;
  create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz default now(),raw_user_meta_data jsonb not null default '{}',deleted_at timestamptz,created_at timestamptz not null default now(),last_sign_in_at timestamptz);
  create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
  grant usage on schema auth,storage to authenticated;grant execute on function auth.uid() to authenticated;
  create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
  create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text not null);
  alter table storage.objects enable row level security;grant select,insert,delete on storage.objects to authenticated;`);
  await db.exec(await readFile(new URL('../supabase/install.sql',import.meta.url),'utf8'));
  for(const [name,id]of Object.entries(ids))await db.query('insert into auth.users(id,email) values($1,$2)',[id,name==='staff'?'contabilidade.rubenrodrigues@gmail.com':name+'@example.com']);
  await db.query('insert into public.staff_users(user_id) values($1) on conflict do nothing',[ids.staff]);
  const actor=async id=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
  const one=async(sql,params=[])=>(await db.query(sql,params)).rows[0];
  // Os perfis nascem no primeiro contexto do portal, como em produção.
  for(const id of [ids.staff,ids.a,ids.b]){await actor(id);await db.query('select public.get_portal_context()');}

  let empresa,outra;
  await t.test('a client sees a company only with the Empresas access and an active link',async()=>{
   await actor(ids.staff);
   empresa=(await one("select public.create_company('Empresa A, Lda','500000000',$1) as id",[ids.a])).id;
   outra=(await one("select public.create_company('Empresa B, Lda','500000001',$1) as id",[ids.b])).id;
   await actor(ids.a);
   assert.equal((await one('select public.pode_aceder_empresa($1) as v',[empresa])).v,false);
   assert.deepEqual((await one('select public.portal_empresas() as p')).p.empresas,[]);
   await actor(ids.staff);
   await db.query('select public.definir_acessos($1,false,true)',[ids.a]);
   await db.query('select public.definir_acessos($1,false,true)',[ids.b]);
   await actor(ids.a);
   const p=(await one('select public.portal_empresas() as p')).p;
   assert.equal(p.acesso_empresas,true);assert.equal(p.acesso_irs,false);
   assert.deepEqual(p.empresas.map(e=>e.id),[empresa]);
   assert.equal(p.empresas[0].tem_cegid,false);
   assert.equal((await one('select public.pode_aceder_empresa($1) as v',[outra])).v,false);
   await assert.rejects(db.query('select public.empresa_resumo($1)',[outra]),/Sem acesso/);
   await actor(ids.staff);await db.query('update public.company_users set active=false where company_id=$1',[empresa]);
   await actor(ids.a);assert.equal((await one('select public.pode_aceder_empresa($1) as v',[empresa])).v,false);
   await actor(ids.staff);await db.query('update public.company_users set active=true where company_id=$1',[empresa]);
  });

  await t.test('only the accountant sets the cut-off date, never in the future, with history',async()=>{
   await actor(ids.a);
   await assert.rejects(db.query("select public.definir_data_corte($1,'2026-01-31')",[empresa]),/contabilista/);
   assert.equal((await db.query("update public.companies set data_corte='2030-01-01' where id=$1 returning id",[empresa])).rows.length,0);
   await actor(ids.staff);
   await assert.rejects(db.query("select public.definir_data_corte($1,current_date+10)",[empresa]),/futura/);
   await db.exec('reset role');await db.query("insert into public.empresa_cegid_cache(company_id,chave,dados) values($1,'x','{}')",[empresa]);
   await actor(ids.staff);
   await db.query("select public.definir_data_corte($1,'2026-09-30','Setembro fechado')",[empresa]);
   assert.equal((await one('select data_corte::text as d from public.companies where id=$1',[empresa])).d,'2026-09-30');
   await db.exec('reset role');
   assert.equal((await one('select count(*)::int as n from public.empresa_cegid_cache where company_id=$1',[empresa])).n,0);
   await actor(ids.a);
   assert.equal((await one('select count(*)::int as n from public.empresa_cortes')).n,1);
   const r=(await one('select public.empresa_resumo($1) as r',[empresa])).r;
   assert.equal(r.empresa.data_corte,'2026-09-30');
   assert.equal(r.atividade[0].tipo,'data_corte');
  });

  await t.test('monthly documents: pending, stored, received; late after the 10th; private per company',async()=>{
   await actor(ids.a);
   const atual=(await one("select public.mes_lisboa()::text as m")).m;
   await assert.rejects(db.query("select public.preparar_documento_empresa($1,(public.mes_lisboa()+interval '1 month')::date,'compras','f.pdf','application/pdf',10)",[empresa]),/Mês inválido/);
   await assert.rejects(db.query("select public.preparar_documento_empresa($1,public.mes_lisboa(),'compras','f.pdf','application/pdf',10)",[outra]),/Sem acesso/);
   const doc=(await one("select public.preparar_documento_empresa($1,public.mes_lisboa(),'compras','Fatura EDP.pdf','application/pdf',1200,null,'Luz') as d",[empresa])).d;
   assert.match(doc.caminho,new RegExp(`^${empresa}/${atual.slice(0,7)}/[0-9a-f-]{36}\\.pdf$`));
   await assert.rejects(db.query('select public.concluir_documento_empresa($1)',[doc.id]),/ainda não chegou/);
   // Só se pode carregar o ficheiro de uma linha pendente própria.
   await actor(ids.b);
   await assert.rejects(db.query("insert into storage.objects(bucket_id,name) values('empresas-documentos',$1)",[doc.caminho]));
   await actor(ids.a);
   await db.query("insert into storage.objects(bucket_id,name) values('empresas-documentos',$1)",[doc.caminho]);
   const fim=(await one('select public.concluir_documento_empresa($1) as r',[doc.id])).r;
   assert.equal(fim.atrasado,false);
   assert.equal((await one('select estado from public.empresa_documentos where id=$1',[doc.id])).estado,'recebido');
   // Um mês com o prazo já passado fica marcado como atrasado.
   const velho=(await one("select public.preparar_documento_empresa($1,(public.mes_lisboa()-interval '2 months')::date,'vendas','v.jpg','image/webp',500) as d",[empresa])).d;
   await db.query("insert into storage.objects(bucket_id,name) values('empresas-documentos',$1)",[velho.caminho]);
   assert.equal((await one('select public.concluir_documento_empresa($1) as r',[velho.id])).r.atrasado,true);
   await actor(ids.b);
   assert.equal((await one('select count(*)::int as n from public.empresa_documentos')).n,0);
   assert.equal((await one("select count(*)::int as n from storage.objects where bucket_id='empresas-documentos'")).n,0);
   await assert.rejects(db.query('select public.eliminar_documento_empresa($1)',[doc.id]),/indisponível/);
   await actor(ids.a);
   // Apagar: primeiro o ficheiro (política), depois a linha.
   await assert.rejects(db.query('select public.eliminar_documento_empresa($1)',[velho.id]),/Apague primeiro/);
   await db.query("delete from storage.objects where bucket_id='empresas-documentos' and name=$1",[velho.caminho]);
   await db.query('select public.eliminar_documento_empresa($1)',[velho.id]);
   // O contabilista revê; um documento visto já não se apaga.
   await assert.rejects(db.query("select public.rever_documento_empresa($1,'visto')",[doc.id]),/contabilista/);
   await actor(ids.staff);
   await db.query("select public.rever_documento_empresa($1,'devolvido','Ilegível')",[doc.id]);
   await actor(ids.a);
   assert.equal((await db.query("delete from storage.objects where name=$1 returning id",[doc.caminho])).rows.length,0);
   await assert.rejects(db.query('select public.eliminar_documento_empresa($1)',[doc.id]),/revisto/);
   const r=(await one('select public.empresa_resumo($1) as r',[empresa])).r;
   assert.equal(r.meses[0].documentos,1);assert.equal(r.meses[0].devolvidos,1);
  });

  await t.test('month completion, review, messages and deadlines',async()=>{
   await actor(ids.a);
   await db.query('select public.marcar_mes_completo($1,public.mes_lisboa(),true)',[empresa]);
   await assert.rejects(db.query('select public.conferir_mes_empresa($1,public.mes_lisboa(),true)',[empresa]),/contabilista/);
   await db.query("select public.enviar_mensagem_empresa($1,'Bom dia, falta algo?')",[empresa]);
   await assert.rejects(db.query("select public.enviar_mensagem_empresa($1,'x')",[outra]),/Sem acesso/);
   await assert.rejects(db.query("insert into public.empresa_mensagens(company_id,autor_id,do_gabinete,corpo) values($1,$2,true,'falsa')",[empresa,ids.a]));
   await assert.rejects(db.query("insert into public.empresa_prazos(company_id,titulo,data,criado_por) values(null,'x',current_date,$1)",[ids.a]));
   await actor(ids.staff);
   await db.query('select public.conferir_mes_empresa($1,public.mes_lisboa(),true,$2)',[empresa,'Tudo certo']);
   assert.equal((await one('select (public.gestao_empresas()->>\'empresas\')::jsonb as e')).e.find(e=>e.id===empresa).mensagens,1);
   assert.equal((await one('select public.ler_mensagens_empresa($1) as n',[empresa])).n,1);
   await db.query("select public.enviar_mensagem_empresa($1,'Está tudo, obrigado.')",[empresa]);
   await db.query("insert into public.empresa_prazos(company_id,titulo,data,criado_por) values(null,'Geral',current_date+5,$1),($2,'Só A',current_date+3,$1),($3,'Só B',current_date+3,$1)",[ids.staff,empresa,outra]);
   await actor(ids.a);
   assert.deepEqual((await db.query('select titulo from public.empresa_prazos order by titulo')).rows.map(r=>r.titulo),['Geral','Só A']);
   const r=(await one('select public.empresa_resumo($1) as r',[empresa])).r;
   assert.equal(r.mensagens_por_ler,1);assert.equal(r.ultima_mensagem.do_gabinete,true);
   assert.ok(r.meses[0].completo_em);assert.ok(r.meses[0].conferido_em);
   assert.deepEqual(r.prazos.map(p=>p.titulo),['Só A','Geral']);
   await assert.rejects(db.query('select public.gestao_empresas()'),/Not authorized/);
  });

  await t.test('the activity log and the Cegid cache are written only by the server',async()=>{
   await actor(ids.a);
   await assert.rejects(db.query("select public.registar_empresa($1,'login','x')",[empresa]),/permission denied/);
   await assert.rejects(db.query("insert into public.empresa_atividade(company_id,tipo) values($1,'falso')",[empresa]));
   await assert.rejects(db.query('select * from public.empresa_cegid_cache'));
   await db.exec('reset role');await db.exec('set role anon');
   await assert.rejects(db.query('select public.portal_empresas()'),/permission denied/);
   await db.exec('reset role');
   const abertas=(await one("select count(*)::int as n from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f' and has_function_privilege('anon',p.oid,'execute')")).n;
   assert.equal(abertas,0);
  });
 }finally{await db.close();}
});
