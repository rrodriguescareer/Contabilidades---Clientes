import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';

const ids={staff:'30000000-0000-4000-8000-000000000001',a:'30000000-0000-4000-8000-000000000002',b:'30000000-0000-4000-8000-000000000003',guest:'30000000-0000-4000-8000-000000000004',unconfirmed:'30000000-0000-4000-8000-000000000005'};
test('production registration, administration, quotations, checkout and private originals',async t=>{
 const db=new PGlite();
 try{
  await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create schema storage;
  create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz,raw_user_meta_data jsonb not null default '{}',deleted_at timestamptz,created_at timestamptz not null default now(),last_sign_in_at timestamptz);
  create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
  grant usage on schema auth,storage to authenticated;grant execute on function auth.uid() to authenticated;
  create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
  create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text not null);
  alter table storage.objects enable row level security;grant select,insert on storage.objects to authenticated;`);
  await db.exec(await readFile(new URL('../supabase/install.sql',import.meta.url),'utf8'));
  for(const [name,id]of Object.entries(ids))await db.query('insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) values($1,$2,$3,$4)',[id,name==='staff'?'contabilidade.rubenrodrigues@gmail.com':name+'@example.com',name==='unconfirmed'?null:new Date(),JSON.stringify({terms_accepted:true,terms_version:'2026-10-23.3',privacy_version:'2026-10-23.3'})]);
  const actor=async(id,role='authenticated')=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role '+role);};
  const save=async(id,name,nif)=>{await actor(id);return(await db.query("select public.save_personal_profile($1,'1980-01-01',$2,'+351 936432519','Rua de exemplo 1','4470-147','Maia',false) as id",[name,nif])).rows[0].id;};
  let a,b,ca,holder,spouse,year=2000;
  await t.test('email-only registration has no fiscal data; confirmed clients self-onboard atomically',async()=>{
   await actor(ids.a);assert.equal((await db.query('select nif from public.profiles')).rows[0].nif,null);
   assert.equal((await db.query('select * from public.client_accounts')).rows.length,0);
   a=await save(ids.a,'Client A','123456789');b=await save(ids.b,'Client B','223456789');
   await actor(ids.a);ca=(await db.query('select id from public.irs_cases where account_id=$1',[a])).rows[0].id;
   holder=(await db.query('select person_id from public.case_people where case_id=$1',[ca])).rows[0].person_id;
   assert.ok((await db.query('select onboarding_completed_at from public.profiles')).rows[0].onboarding_completed_at);
   assert.equal(await save(ids.a,'Updated Client A','123456789'),a);
   assert.equal((await db.query('select count(*)::int as n from public.client_accounts')).rows[0].n,1);
   assert.equal((await db.query('select full_name from public.people where id=$1',[holder])).rows[0].full_name,'Updated Client A');
   await actor(ids.unconfirmed);assert.equal((await db.query('select public.user_enabled($1) as enabled',[ids.unconfirmed])).rows[0].enabled,false);
   await assert.rejects(save(ids.unconfirmed,'No confirmation','323456789'));
  });
  await t.test('only the verified accountant identity can administer clients',async()=>{
   await actor(ids.staff);assert.equal((await db.query('select public.is_staff() as value')).rows[0].value,true);
   await assert.rejects(db.query('select public.set_user_blocked($1,true)',[ids.staff]));
   await actor(ids.a);await assert.rejects(db.query('select public.set_user_blocked($1,true)',[ids.b]));
   await db.exec('reset role');await db.query('insert into public.staff_users(user_id) values($1)',[ids.a]);
   await actor(ids.a);assert.equal((await db.query('select public.is_staff() as value')).rows[0].value,false);
   assert.equal((await db.query('select * from public.profiles')).rows.length,1);
  });
  await t.test('companies can be created and associated by the accountant without granting another client access',async()=>{
   await actor(ids.a);await assert.rejects(db.query('select public.create_company($1,$2,$3)',['Wrong','500000001',ids.a]));
   await actor(ids.staff);const company=(await db.query('select public.create_company($1,$2,$3) as id',['Company A','500000001',ids.a])).rows[0].id;
   await actor(ids.a);assert.equal((await db.query('select id from public.companies')).rows[0].id,company);
   await actor(ids.b);assert.equal((await db.query('select * from public.companies')).rows.length,0);
   await assert.rejects(db.query('insert into public.company_users(company_id,user_id) values($1,$2)',[company,ids.b]));
  });
  await t.test('invitations bind a confirmed email and reveal no household fiscal records to the guest',async()=>{
   await actor(ids.a);spouse=(await db.query("select public.add_case_person($1,$2,'Spouse','1982-01-01','333444555','conjuge','guest@example.com',false) as id",[a,ca])).rows[0].id;
   const token='ab'.repeat(32),hash=createHash('sha256').update(token).digest('hex');
   const invitation=(await db.query('select public.create_household_invitation($1,$2,$3,$4) as id',[a,spouse,'guest@example.com',hash])).rows[0].id;
   await assert.rejects(db.query('select token_hash from public.household_invitations'));
   await actor(ids.b);await assert.rejects(db.query('select public.accept_household_invitation($1)',[token]));
   await actor(ids.guest);await db.query('select public.accept_household_invitation($1)',[token]);await db.query('select public.accept_household_invitation($1)',[token]);
   assert.equal((await db.query('select state from public.household_invitations where id=$1',[invitation])).rows[0].state,'accepted');
   assert.equal((await db.query('select * from public.people')).rows.length,0);
   assert.equal((await db.query('select * from public.account_access')).rows.length,0);
   await actor(ids.staff);assert.equal((await db.query('select accepted_by from public.household_invitations where id=$1',[invitation])).rows[0].accepted_by,ids.guest);
  });
  // O pagamento só abre com o processo pronto a submeter: o titular tem de ter a senha das Finanças guardada.
  const newCase=async(account=a)=>{await actor(ids.staff);const id=(await db.query('select public.create_irs_case($1,$2) as id',[account,year++])).rows[0].id;
   await db.exec('reset role');await db.query("insert into public.tax_credentials(person_id,account_id,encrypted_password) select cp.person_id,cp.account_id,'ensaio' from public.case_people cp where cp.case_id=$1 and cp.relationship='titular' on conflict (person_id) do nothing",[id]);
   await actor(account===a?ids.a:ids.b);return id;};
  const income=async(process,category,{person=holder,property=null,account=a}={})=>db.query("insert into public.income_records(account_id,case_id,category,person_id,property_id,title,mode) values($1,$2,$3,$4,$5,'Income','documents')",[account,process,category,person,property]);
  const property=async(process,account=a)=>(await db.query("insert into public.property_assets(account_id,case_id,label) values($1,$2,'Property') returning id",[account,process])).rows[0].id;
  const quote=async(process,coupon='',account=a)=>(await db.query('select public.quote_irs_checkout($1,$2,$3) as quote',[account,process,coupon])).rows[0].quote;
  await t.test('pricing counts people, categories and distinct properties using integer cents',async()=>{
   let c=await newCase();await income(c,'employment');assert.equal((await quote(c)).total_cents,1850);
   await income(c,'independent');assert.equal((await quote(c)).total_cents,3350);
   await db.query("select public.link_case_person($1,$2,$3,'conjuge')",[a,c,spouse]);await income(c,'pension',{person:spouse});assert.equal((await quote(c)).total_cents,3850);
   for(const [n,expected]of [[1,1850],[2,1850],[3,2850],[5,2850],[6,3850]]){
    c=await newCase();for(let i=0;i<n;i++)await income(c,'property_rent',{property:await property(c)});
    assert.equal((await quote(c)).total_cents,expected,'rent-only '+n);
    await income(c,'employment');assert.equal((await quote(c)).total_cents,n<=2?2350:expected,'mixed rent '+n);
   }
   c=await newCase();await income(c,'securities');await income(c,'securities');assert.equal((await quote(c)).total_cents,2850);
   c=await newCase();const p=await property(c);await income(c,'property_sale',{property:p});await income(c,'property_sale',{property:p});assert.equal((await quote(c)).total_cents,2850);
   await income(c,'property_sale',{property:await property(c)});assert.equal((await quote(c)).total_cents,3850);
   await income(c,'deduction');assert.equal((await quote(c)).total_cents,3850);
   const empty=await newCase();await assert.rejects(quote(empty));
  });
  let discount;
  await t.test('discounts combine customer, date and usage restrictions; an assigned code cannot be replaced',async()=>{
   await actor(ids.staff);discount=(await db.query("insert into public.discount_codes(code,kind,value,allowed_user,starts_at,ends_at,max_uses) values('ONLY_A','percentage',1000,$1,now()-interval '1 day',now()+interval '1 day',1) returning id",[ids.a])).rows[0].id;
   await db.query('select public.set_client_billing($1,false,$2)',[ids.a,discount]);
   const c=await newCase();await income(c,'employment');const q=await quote(c,'NOT_A_REAL_CODE');assert.equal(q.discount_code,'ONLY_A');assert.equal(q.total_cents,1665);
   const attempt=(await db.query('select public.begin_irs_checkout($1,$2,$3) as data',[a,c,'ignored'])).rows[0].data;
   const another=await newCase();await income(another,'employment');await assert.rejects(quote(another));
   await actor(ids.staff);await db.query('select public.set_client_billing($1,false,null)',[ids.a]);
   await actor(ids.b);const cb=(await db.query('select id from public.irs_cases where account_id=$1',[b])).rows[0].id;const pb=(await db.query('select person_id from public.case_people where case_id=$1',[cb])).rows[0].person_id;await income(cb,'employment',{account:b,person:pb});await assert.rejects(quote(cb,'ONLY_A',b));
   await actor(ids.a);await assert.rejects(db.query("update public.irs_checkouts set state='paid' where id=$1",[attempt.id]));
   await assert.rejects(db.query('select public.finish_revolut_order($1,$2,$3,$4,1665,$5)',[attempt.id,'order',attempt.id,'COMPLETED','EUR']));
  });
  await t.test('expired/future coupons fail; percentage rounding and reserved global caps are enforced',async()=>{
   await actor(ids.staff);
   await db.exec("insert into public.discount_codes(code,kind,value,starts_at,ends_at) values('FUTURE','fixed',100,now()+interval '1 day',null),('EXPIRED','fixed',100,null,now()-interval '1 day'),('ROUND','percentage',500,null,null);insert into public.discount_codes(code,kind,value,max_uses) values('GLOBAL_ONCE','fixed',100,1);");
   const c=await newCase();await income(c,'employment');
   await assert.rejects(quote(c,'FUTURE'));await assert.rejects(quote(c,'EXPIRED'));assert.equal((await quote(c,'ROUND')).discount_cents,93);
   await assert.rejects(db.query("select public.begin_irs_checkout($1,$2,'',1)",[a,c]));
   assert.equal((await db.query('select count(*)::int as n from public.irs_checkouts where case_id=$1',[c])).rows[0].n,0);
   const attempt=(await db.query("select public.begin_irs_checkout($1,$2,'GLOBAL_ONCE',1750) as data",[a,c])).rows[0].data;
   await actor(ids.b);const cb=(await db.query('select id from public.irs_cases where account_id=$1',[b])).rows[0].id;await assert.rejects(quote(cb,'GLOBAL_ONCE',b));
   await actor(ids.staff,'service_role');await db.query('select public.attach_revolut_order($1,$2,$3)',[attempt.id,'provider-cancelled','https://checkout.revolut.com/pay/cancelled']);
   await db.query('select public.finish_revolut_order($1,$2,$3,$4,1750,$5)',[attempt.id,'provider-cancelled',attempt.id,'CANCELLED','EUR']);
   await actor(ids.b);assert.equal((await quote(cb,'GLOBAL_ONCE',b)).total_cents,1750);
  });
  await t.test('a free client can submit without an external charge and cannot grant themselves free service',async()=>{
   await actor(ids.a);await assert.rejects(db.query('select public.set_client_billing($1,true,null)',[ids.a]));
   await actor(ids.staff);await db.query('select public.set_client_billing($1,true,null)',[ids.a]);
   const c=await newCase();await income(c,'employment');assert.equal((await quote(c)).total_cents,0);
   const result=(await db.query("select public.begin_irs_checkout($1,$2,'') as data",[a,c])).rows[0].data;assert.equal(result.state,'paid');
   assert.equal((await db.query('select status from public.irs_cases where id=$1',[c])).rows[0].status,'submitted_by_client');
   assert.equal((await db.query('select provider_order_id from public.irs_checkouts where id=$1',[result.id])).rows[0].provider_order_id,null);
   await actor(ids.staff);await db.query('select public.set_client_billing($1,false,null)',[ids.a]);
  });
  await t.test('payment does not open while the case cannot be submitted',async()=>{
   const c=await newCase();await income(c,'employment');
   await db.exec('reset role');await db.query('delete from public.tax_credentials where person_id in (select person_id from public.case_people where case_id=$1)',[c]);
   await actor(ids.a);await assert.rejects(db.query("select public.begin_irs_checkout($1,$2,'')",[a,c]),/Incomplete case/);
   // Submeter sem estar pronto devolve o que falta, sem mudar o estado.
   const tentativa=(await db.query('select public.submeter_processo($1) as r',[c])).rows[0].r;
   assert.equal(tentativa.ok,false);assert.ok(tentativa.faltas.length>0);
  });
  await t.test('a client can submit first and pay afterwards, in any phase until closed',async()=>{
   const c=await newCase();await income(c,'employment');
   const r=(await db.query('select public.submeter_processo($1) as r',[c])).rows[0].r;
   assert.equal(r.ok,true);assert.equal(r.pago,false);
   assert.equal((await db.query('select status from public.irs_cases where id=$1',[c])).rows[0].status,'submitted_by_client');
   await actor(ids.staff);await db.query("update public.irs_cases set status='filed' where id=$1",[c]);
   await actor(ids.a);
   const attempt=(await db.query("select public.begin_irs_checkout($1,$2,'') as data",[a,c])).rows[0].data;
   assert.equal(attempt.created,true);
   await actor(ids.staff,'service_role');
   await db.query("select public.anexar_sessao_de_pagamento($1,'cs_test_depois','')",[attempt.id]);
   await db.query("select public.finalizar_pagamento_stripe($1,'cs_test_depois',$2,true,false,$3,'eur')",[attempt.id,attempt.id,attempt.amount_cents]);
   await actor(ids.a);
   assert.equal((await db.query('select state from public.irs_checkouts where id=$1',[attempt.id])).rows[0].state,'paid');
   // Pagar depois não mexe na fase do processo.
   assert.equal((await db.query('select status from public.irs_cases where id=$1',[c])).rows[0].status,'filed');
   assert.equal((await db.query("select title from public.progress_events where case_id=$1 order by created_at desc limit 1",[c])).rows[0].title,'Pagamento recebido');
   // Um processo fechado e por pagar já não abre pagamento.
   const fechado=await newCase();await income(fechado,'employment');
   await actor(ids.staff);await db.query("update public.irs_cases set status='closed' where id=$1",[fechado]);
   await actor(ids.a);await assert.rejects(db.query("select public.begin_irs_checkout($1,$2,'')",[a,fechado]),/Case is closed/);
  });
  await t.test('checkout freezes fiscal writes; only a matching verified provider order can settle it once',async()=>{
   const c=await newCase();await income(c,'employment');
   const attempt=(await db.query("select public.begin_irs_checkout($1,$2,'') as data",[a,c])).rows[0].data;
   assert.equal((await db.query("select public.begin_irs_checkout($1,$2,'') as data",[a,c])).rows[0].data.id,attempt.id);
   await assert.rejects(db.query('select public.submit_case($1,$2)',[a,c]));
   await actor(ids.staff,'service_role');await db.query('select public.attach_revolut_order($1,$2,$3)',[attempt.id,'provider-order-1','https://checkout.revolut.com/pay/order']);
   // O congelamento começa quando há uma ordem aberta no fornecedor (pending):
   // uma tentativa que ficou a meio da criação já não tranca o processo.
   await actor(ids.a);await assert.rejects(income(c,'independent'));
   await actor(ids.staff);await assert.rejects(income(c,'independent'));
   await actor(ids.staff,'service_role');
   await assert.rejects(db.query('select public.finish_revolut_order($1,$2,$3,$4,1,$5)',[attempt.id,'provider-order-1',attempt.id,'COMPLETED','EUR']));
   await assert.rejects(db.query('select public.finish_revolut_order($1,$2,$3,$4,1850,$5)',[attempt.id,'provider-order-1','wrong-reference','COMPLETED','EUR']));
   for(let i=0;i<2;i++)await db.query('select public.finish_revolut_order($1,$2,$3,$4,1850,$5)',[attempt.id,'provider-order-1',attempt.id,'COMPLETED','EUR']);
   await actor(ids.a);assert.equal((await db.query('select state from public.irs_checkouts where id=$1',[attempt.id])).rows[0].state,'paid');
   assert.equal((await db.query('select count(*)::int as n from public.progress_events where case_id=$1',[c])).rows[0].n,1);
   assert.equal((await db.query('select status from public.irs_cases where id=$1',[c])).rows[0].status,'submitted_by_client');
  });
  await t.test('a client upload is finished only once the file is in storage',async()=>{
   const c=await newCase();
   const doc=(await db.query("select public.prepare_irs_document($1,$2,null,'PPR','ppr.webp','image/webp',10,$3) as data",[a,c,'34'.repeat(32)])).rows[0].data;
   const concluir=()=>db.query("select public.concluir_documento($1,'deduction',null,'Comprovativo do PPR')",[doc.id]);
   await assert.rejects(concluir(),/File not received/);
   await db.query("insert into storage.objects(bucket_id,name) values('irs-documents',$1)",[doc.path]);
   await actor(ids.b);await assert.rejects(concluir());
   await actor(ids.a);await concluir();await concluir();
   const row=(await db.query('select state,category,description from public.documents where id=$1',[doc.id])).rows[0];
   assert.deepEqual({...row},{state:'uploaded',category:'deduction',description:'Comprovativo do PPR'});
   // A senha guardada pelo gabinete aparece ao cliente como guardada.
   const membros=(await db.query("select public.espaco_irs('agregado',$1) as d",[c])).rows[0].d.membros;
   assert.equal(membros.find((m)=>m.relacao==='titular').tem_senha,true);
  });
  await t.test('identical documents reuse private bytes within one case only',async()=>{
   const c=await newCase(),hash='12'.repeat(32);
   const prepare=async()=> (await db.query("select public.prepare_irs_document($1,$2,null,'Other','file.pdf','application/pdf',10,$3) as data",[a,c,hash])).rows[0].data;
   const first=await prepare();assert.equal(first.reused,false);
   // Repetir um envio que ficou a meio retoma o mesmo documento.
   const again=await prepare();assert.equal(again.id,first.id);assert.equal(again.retomado,true);
   await db.query("update public.documents set state='uploaded' where id=$1",[first.id]);
   const second=await prepare();assert.equal(second.reused,true);assert.equal(second.path,first.path);assert.notEqual(second.id,first.id);
   await db.query("update public.documents set state='uploaded' where id=$1",[second.id]);
   await actor(ids.b);assert.equal((await db.query('select * from public.documents')).rows.length,0);
   await assert.rejects(db.query("select public.prepare_irs_document($1,$2,null,'Other','file.pdf','application/pdf',10,$3)",[a,c,hash]));
  });
  await t.test('blocking revokes reads with an existing session; deleting authentication preserves fiscal originals',async()=>{
   await actor(ids.staff);await db.query('select public.set_user_blocked($1,true)',[ids.a]);
   await actor(ids.a);assert.equal((await db.query('select * from public.client_accounts')).rows.length,0);assert.equal((await db.query('select * from public.documents')).rows.length,0);assert.equal((await db.query('select * from public.companies')).rows.length,0);
   await assert.rejects(save(ids.a,'Cannot bypass block','123456789'));
   await actor(ids.staff);await db.query('select public.prepare_user_deletion($1)',[ids.a]);await db.query('select public.finish_user_deletion($1)',[ids.a]);
   assert.ok((await db.query('select deleted_at from public.profiles where id=$1',[ids.a])).rows[0].deleted_at);
   assert.ok((await db.query('select count(*)::int as n from public.documents where account_id=$1',[a])).rows[0].n>0);
  });
  await t.test('only the administrator can grant professional roles or manage integration credentials',async()=>{
   const professional='30000000-0000-4000-8000-000000000099';
   await db.exec('reset role');await db.query('insert into auth.users(id,email,email_confirmed_at) values($1,$2,now())',[professional,'professional@example.com']);
   await actor(professional);assert.equal((await db.query('select public.is_staff() as staff')).rows[0].staff,false);
   await assert.rejects(db.query('select public.set_staff_access($1,true)',[professional]));
   await actor(ids.staff);await db.query('select public.set_staff_access($1,true)',[professional]);
   await actor(professional);assert.equal((await db.query('select public.is_staff() as staff')).rows[0].staff,true);
   assert.equal((await db.query('select public.is_platform_owner() as owner')).rows[0].owner,false);
   assert.ok((await db.query('select * from public.irs_cases')).rows.length>0);
   await assert.rejects(db.query('select public.set_user_blocked($1,true)',[ids.b]));
   await assert.rejects(db.query('select public.set_client_billing($1,true,null)',[ids.b]));
   await assert.rejects(db.query('select public.create_company($1,$2,$3)',['Forbidden','500000099',ids.b]));
   await assert.rejects(db.query('select * from public.integration_secrets'));
   assert.equal((await db.query('select * from public.payment_settings')).rows.length,0);
   await actor(ids.staff);await assert.rejects(db.query('select * from public.integration_secrets'));
   await actor(ids.staff,'service_role');await db.query("insert into public.integration_secrets(scope,encrypted_value) values('cegid:example','ciphertext-fixture')");
   await actor(ids.b);assert.equal((await db.query('select public.get_portal_context() as c')).rows[0].c.accounts.length,1);
   assert.equal((await db.query('select public.get_portal_context() as c')).rows[0].c.cases.every(c=>c.account_id===b&&c.campaign===2026),true);
   await assert.rejects(db.query('select * from public.integration_secrets'));
   await actor(ids.staff);await db.query('select public.set_staff_access($1,false)',[professional]);
   await actor(professional);assert.equal((await db.query('select * from public.irs_cases')).rows.length,0);
  });
  await t.test('full deletion removes the owned account and everything hanging from it, confirmed or not',async()=>{
   await actor(ids.staff);
   const before=(await db.query('select count(*)::int as n from public.client_accounts')).rows[0].n;
   const contas=(await db.query("select account_id from public.account_access where user_id=$1 and role='owner'",[ids.b])).rows.map(r=>r.account_id);
   assert.ok(contas.length>0);
   await actor(ids.a);await assert.rejects(db.query('select public.eliminar_utilizador($1)',[ids.b]));
   await actor(ids.staff);const r=(await db.query('select public.eliminar_utilizador($1) as r',[ids.b])).rows[0].r;
   assert.equal(r.contas,contas.length);
   for(const tabela of ['irs_cases','people','income_records','documents','messages','irs_checkouts','account_access']){
    assert.equal((await db.query(`select count(*)::int as n from public.${tabela} where account_id = any($1)`,[contas])).rows[0].n,0,tabela);
   }
   assert.equal((await db.query('select count(*)::int as n from public.client_accounts')).rows[0].n,before-contas.length);
   assert.equal((await db.query('select count(*)::int as n from public.profiles where id=$1',[ids.b])).rows[0].n,0);
   // Um utilizador que nunca confirmou o email também sai.
   await db.query('select public.eliminar_utilizador($1)',[ids.unconfirmed]);
   assert.equal((await db.query('select count(*)::int as n from public.profiles where id=$1',[ids.unconfirmed])).rows[0].n,0);
  });
 }finally{await db.close();}
});
