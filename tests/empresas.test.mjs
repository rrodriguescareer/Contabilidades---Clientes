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
   await actor(ids.staff);
   await db.query("select public.definir_data_corte($1,'2026-09-30','Setembro fechado')",[empresa]);
   assert.equal((await one('select data_corte::text as d from public.companies where id=$1',[empresa])).d,'2026-09-30');
   // A data de corte muda a versão do Cegid: a cache do portal deixa de servir.
   assert.equal((await one('select cegid_versao from public.companies where id=$1',[empresa])).cegid_versao,1);
   assert.equal((await one('select public.renovar_cegid_empresa($1) as v',[empresa])).v,2);
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

  await t.test('start date, blocked and closed months limit what the client can send',async()=>{
   await actor(ids.a);
   await assert.rejects(db.query("select public.definir_inicio_empresa($1,'2026-01-01')",[empresa]),/contabilista/);
   await assert.rejects(db.query('select public.definir_mes_empresa($1,public.mes_lisboa(),true,false)',[empresa]),/contabilista/);
   await actor(ids.staff);
   await db.query("select public.definir_inicio_empresa($1,(public.mes_lisboa()-interval '1 month')::date)",[empresa]);
   await db.query("select public.definir_mes_empresa($1,(public.mes_lisboa()-interval '1 month')::date,true,false)",[empresa]);
   await db.query("select public.definir_mes_empresa($1,public.mes_lisboa(),false,true)",[empresa]);
   await actor(ids.a);
   const tentar=intervalo=>db.query(`select public.preparar_documento_empresa($1,(public.mes_lisboa()-interval '${intervalo}')::date,'compras','x.pdf','application/pdf',10)`,[empresa]);
   await assert.rejects(tentar('2 months'),/anterior ao início/);
   await assert.rejects(tentar('1 month'),/fechado para envio/);
   await assert.rejects(tentar('0 months'),/fechado para envio/);
   await assert.rejects(db.query('select public.marcar_mes_completo($1,public.mes_lisboa(),true)',[empresa]),/fechado pelo contabilista/);
   const r=(await one('select public.empresa_resumo($1) as r',[empresa])).r;
   assert.equal(r.meses.length,2);assert.ok(r.meses[0].fechado_em);assert.equal(r.meses[1].bloqueado,true);
   await actor(ids.staff);
   await db.query("select public.definir_mes_empresa($1,public.mes_lisboa(),false,false)",[empresa]);
   await db.query("select public.definir_inicio_empresa($1,null)",[empresa]);
  });

  await t.test('both sides edit the company file, every change is kept, NIF is checked',async()=>{
   await actor(ids.a);
   await assert.rejects(db.query("select public.guardar_ficha_empresa($1,'{\"nif\":\"500000001\"}')",[empresa]),/NIF inválido/);
   await assert.rejects(db.query("select public.guardar_ficha_empresa($1,'{\"nif\":\"500000001\"}')",[outra]),/Sem acesso/);
   await assert.rejects(db.query("select public.guardar_ficha_empresa($1,'{\"saldo\":\"1\"}')",[empresa]),/Campo desconhecido/);
   const n=(await one("select public.guardar_ficha_empresa($1,$2::jsonb) as n",[empresa,JSON.stringify({regime_iva:'trimestral',cae:'69200',iban:'pt50 0002 0123 1234 5678 9015 4',tem_trabalhadores:true,capital_social:'5000'})])).n;
   assert.equal(n,5);
   assert.equal((await one('select iban from public.empresa_fichas where company_id=$1',[empresa])).iban,'PT50000201231234567890154');
   await actor(ids.staff);
   assert.equal((await one("select public.guardar_ficha_empresa($1,$2::jsonb) as n",[empresa,JSON.stringify({nif:'123456789',capital_social:'5000.00'})])).n,1);
   await actor(ids.a);
   const h=(await db.query('select campo,antes,depois,origem from public.empresa_ficha_historico order by id')).rows;
   assert.deepEqual(h.map(x=>x.campo),['cae','regime_iva','tem_trabalhadores','capital_social','iban','nif']);
   assert.deepEqual(h.map(x=>x.origem),['portal','portal','portal','portal','portal','gestao']);
   assert.deepEqual([h[5].antes,h[5].depois],['500000000','123456789']);
   await actor(ids.b);
   assert.equal((await one('select count(*)::int as n from public.empresa_ficha_historico')).n,0);
  });

  await t.test('alerts reach only their companies and are read per person',async()=>{
   await actor(ids.staff);
   await db.query("insert into public.empresa_alertas(company_id,titulo,nivel,criado_por) values($1,'Só A','urgente',$3),($2,'Só B','info',$3),(null,'Todos','aviso',$3)",[empresa,outra,ids.staff]);
   await actor(ids.a);
   const vistos=(await db.query('select id,titulo from public.empresa_alertas order by titulo')).rows;
   assert.deepEqual(vistos.map(x=>x.titulo),['Só A','Todos']);
   await assert.rejects(db.query("insert into public.empresa_alertas(company_id,titulo,criado_por) values($1,'falso',$2)",[empresa,ids.a]));
   await db.query('select public.ler_alerta_empresa($1)',[vistos[0].id]);
   assert.equal((await one('select count(*)::int as n from public.empresa_alertas_lidos')).n,1);
   const deB=(await one("select id from public.empresa_alertas where titulo='Só B'"));
   assert.equal(deB,undefined);
  });

  await t.test('personnel requests, monthly payslips and taxes with guides and proofs',async()=>{
   await actor(ids.b);
   await assert.rejects(db.query("select public.comunicar_pessoal($1,'admissao','Alguém','{}')",[outra]),/não tem trabalhadores/);
   await actor(ids.a);
   const pedido=(await one("select public.comunicar_pessoal($1,'admissao','Joana Silva',$2::jsonb) as id",[empresa,JSON.stringify({nif:'123456789',inicio:'2026-11-01'})])).id;
   const anexo=(await one("select public.preparar_ficheiro_empresa($1,'pessoal',$2,'cc.pdf','application/pdf',100) as f",[empresa,pedido])).f;
   await db.query("insert into storage.objects(bucket_id,name) values('empresas-ficheiros',$1)",[anexo.caminho]);
   await db.query('select public.concluir_ficheiro_empresa($1)',[anexo.id]);
   await assert.rejects(db.query("select public.tratar_pessoal($1,'tratado')",[pedido]),/contabilista/);
   await assert.rejects(db.query("select public.preparar_recibos_mes($1,public.mes_lisboa())",[empresa]),/contabilista/);
   await actor(ids.b);
   assert.equal((await one('select count(*)::int as n from public.empresa_pessoal')).n,0);
   assert.equal((await one("select count(*)::int as n from storage.objects where bucket_id='empresas-ficheiros'")).n,0);
   await actor(ids.staff);
   await db.query("select public.tratar_pessoal($1,'tratado','Admissão comunicada à Segurança Social')",[pedido]);
   const recibos=(await one('select public.preparar_recibos_mes($1,public.mes_lisboa()) as id',[empresa])).id;
   const pdf=(await one("select public.preparar_ficheiro_empresa($1,'recibos',$2,'recibos.pdf','application/pdf',100) as f",[empresa,recibos])).f;
   await actor(ids.a);
   assert.equal((await one('select count(*)::int as n from public.empresa_recibos')).n,0); // por publicar
   await actor(ids.staff);
   await db.query("insert into storage.objects(bucket_id,name) values('empresas-ficheiros',$1)",[pdf.caminho]);
   await db.query('select public.concluir_ficheiro_empresa($1)',[pdf.id]);
   const iva=(await one("select public.guardar_imposto(null,$1,'IVA','2026-09','IVA de setembro','DUC 123',1234.56,current_date-1) as id",[empresa])).id;
   const guia=(await one("select public.preparar_ficheiro_empresa($1,'guia',$2,'guia.pdf','application/pdf',100) as f",[empresa,iva])).f;
   await db.query("insert into storage.objects(bucket_id,name) values('empresas-ficheiros',$1)",[guia.caminho]);
   await db.query('select public.concluir_ficheiro_empresa($1)',[guia.id]);
   await actor(ids.a);
   assert.equal((await one('select count(*)::int as n from public.empresa_recibos where publicado_em is not null')).n,1);
   await db.query('select public.registar_descarga_empresa($1)',[pdf.id]);
   assert.ok((await one('select descarregado_em from public.empresa_recibos')).descarregado_em);
   await assert.rejects(db.query("select public.preparar_ficheiro_empresa($1,'guia',$2,'x.pdf','application/pdf',1)",[empresa,iva]),/Apenas o contabilista/);
   await assert.rejects(db.query("select public.guardar_imposto(null,$1,'IVA','x',null,null,1,current_date)",[empresa]),/Apenas o contabilista/);
   const r=(await one('select public.empresa_resumo($1) as r',[empresa])).r;
   assert.equal(r.impostos.length,1);assert.equal(r.impostos[0].atrasado,true);
   const prova=(await one("select public.preparar_ficheiro_empresa($1,'comprovativo',$2,'pago.pdf','application/pdf',100) as f",[empresa,iva])).f;
   await db.query("insert into storage.objects(bucket_id,name) values('empresas-ficheiros',$1)",[prova.caminho]);
   await db.query('select public.concluir_ficheiro_empresa($1)',[prova.id]);
   assert.equal((await one('select estado from public.empresa_impostos where id=$1',[iva])).estado,'pago');
   await db.query('select public.marcar_imposto_pago($1,false)',[iva]);
   await actor(ids.b);
   await assert.rejects(db.query('select public.marcar_imposto_pago($1,true)',[iva]),/indisponível/);
   assert.equal((await one('select count(*)::int as n from public.empresa_impostos')).n,0);
   await actor(ids.staff);
   assert.equal((await one('select public.gestao_empresas() as g')).g.empresas.find(e=>e.id===empresa).impostos_atrasados,1);
  });

  await t.test('the logo lives under the company folder and only its people can change it',async()=>{
   const nome=`${empresa}/logotipo-1700000000.webp`;
   await actor(ids.b);
   await assert.rejects(db.query("insert into storage.objects(bucket_id,name) values('empresas-logotipos',$1)",[nome]));
   await actor(ids.a);
   await assert.rejects(db.query("insert into storage.objects(bucket_id,name) values('empresas-logotipos',$1)",[`${empresa}/outro.webp`]));
   await assert.rejects(db.query('select public.definir_logotipo_empresa($1,$2)',[empresa,nome]),/Logótipo inválido/);
   await db.query("insert into storage.objects(bucket_id,name) values('empresas-logotipos',$1)",[nome]);
   assert.equal((await one('select public.definir_logotipo_empresa($1,$2) as a',[empresa,nome])).a,null);
   assert.equal((await one('select public.portal_empresas() as p')).p.empresas[0].logotipo,nome);
   await assert.rejects(db.query('select public.definir_logotipo_empresa($1,$2)',[outra,nome]),/Sem acesso/);
  });

  await t.test('the activity log and the Cegid cache are written only by the server',async()=>{
   await actor(ids.a);
   await assert.rejects(db.query("select public.registar_empresa($1,'login','x')",[empresa]),/permission denied/);
   await assert.rejects(db.query("insert into public.empresa_atividade(company_id,tipo) values($1,'falso')",[empresa]));
   assert.equal((await one("select to_regclass('public.empresa_cegid_cache') as t")).t,null);
   await assert.rejects(db.query('select public.renovar_cegid_empresa($1)',[empresa]),/Not authorized/);
   await db.exec('reset role');await db.exec('set role anon');
   await assert.rejects(db.query('select public.portal_empresas()'),/permission denied/);
   await db.exec('reset role');
   const abertas=(await one("select count(*)::int as n from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f' and has_function_privilege('anon',p.oid,'execute')")).n;
   assert.equal(abertas,0);
  });
 }finally{await db.close();}
});
