import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

// Local PostgreSQL with minimal Supabase Auth/Storage fixtures. Never contacts Supabase.
const ids={staff:'10000000-0000-4000-8000-000000000001',a:'10000000-0000-4000-8000-000000000002',b:'10000000-0000-4000-8000-000000000003',member:'10000000-0000-4000-8000-000000000004'};
test('shared schema, database constraints and tenant isolation',async t=>{
 const db=new PGlite();
 try{
  await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create schema storage;
  create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb not null default '{}',email_confirmed_at timestamptz default now(),deleted_at timestamptz,created_at timestamptz not null default now(),last_sign_in_at timestamptz);
  create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
  grant usage on schema auth,storage to authenticated;grant execute on function auth.uid() to authenticated;
  create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
  create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text not null);
  alter table storage.objects enable row level security;grant select,insert on storage.objects to authenticated;`);
  // A lista era escrita a mao e ficava para tras de cada migracao nova: o
  // teste passava contra um esquema que ja nao existia. Agora le a pasta,
  // com o mesmo filtro do empacotador.
  const { readdir } = await import('node:fs/promises');
  const pasta = new URL('../supabase/migrations/', import.meta.url);
  for (const nome of (await readdir(pasta)).filter(n=>/^\d+_[a-z0-9_]+\.sql$/.test(n)).sort()) {
    await db.exec(await readFile(new URL(nome, pasta),'utf8'));
  }
  for(const [name,id]of Object.entries(ids)) await db.query('insert into auth.users(id,email,raw_user_meta_data) values($1,$2,$3)',[id,(name==='staff'?'contabilidade.rubenrodrigues@gmail.com':name+'@example.com'),JSON.stringify({terms_accepted:true,terms_version:'2026-10-28.1',privacy_version:'2026-10-28.1',full_name:'Test '+name,birth_date:'1980-01-01',nif:name==='a'?'123456789':name==='b'?'223456789':name==='member'?'323456789':'423456789'})]);
  await db.query('insert into public.staff_users(user_id) values($1) on conflict do nothing',[ids.staff]);
  const actor=async id=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
  await actor(ids.staff);
  const a=(await db.query('select public.approve_client($1,$2,2025) as id',[ids.a,'Account A'])).rows[0].id;
  const b=(await db.query('select public.approve_client($1,$2,2025) as id',[ids.b,'Account B'])).rows[0].id;
  const ca=(await db.query('select id from public.irs_cases where account_id=$1',[a])).rows[0].id;
  const cb=(await db.query('select id from public.irs_cases where account_id=$1',[b])).rows[0].id;
  const pa=(await db.query('select id from public.people where account_id=$1',[a])).rows[0].id;
  const pb=(await db.query('select id from public.people where account_id=$1',[b])).rows[0].id;
  await t.test('acceptance stores server time, current versions and the authenticated user only',async()=>{
   await actor(ids.a);
   let rows=(await db.query('select * from public.legal_acceptances')).rows;
   assert.equal(rows.length,1);assert.equal(rows[0].user_id,ids.a);assert.equal(rows[0].source,'registration');assert.equal(rows[0].terms_version,'2026-10-28.1');assert.ok(rows[0].accepted_at);
   await db.query("select public.record_legal_acceptance('2026-10-28.1','2026-10-28.1')");assert.equal((await db.query('select * from public.legal_acceptances')).rows.length,1);
   await assert.rejects(db.query("select public.record_legal_acceptance('2026-10-23.1','2026-10-23.1')"));
   await assert.rejects(db.query('select public.record_legal_acceptance()'));
   await assert.rejects(db.query("update public.legal_acceptances set accepted_at='2000-01-01' where user_id=$1",[ids.a]));
   await assert.rejects(db.query('insert into public.legal_acceptances(user_id,terms_version,privacy_version,source) values($1,$2,$3,$4)',[ids.b,'forged','forged','registration']));
  });
  await t.test('no acceptance blocks fiscal reads until that user explicitly confirms',async()=>{
   const id='10000000-0000-4000-8000-000000000005';await db.exec('reset role');
   await db.query('insert into auth.users(id,email,raw_user_meta_data) values($1,$2,$3)',[id,'no-consent@example.com',JSON.stringify({full_name:'Pending acceptance',birth_date:'1980-01-01',nif:'623456789'})]);
   await actor(ids.staff);const pending=(await db.query('select public.approve_client($1,$2,2025) as id',[id,'Pending account'])).rows[0].id;
   await actor(id);assert.equal((await db.query('select * from public.legal_acceptances')).rows.length,0);assert.equal((await db.query('select * from public.client_accounts where id=$1',[pending])).rows.length,0);
   await db.query("select public.record_legal_acceptance('2026-10-28.1','2026-10-28.1')");assert.equal((await db.query('select * from public.client_accounts where id=$1',[pending])).rows.length,1);
   assert.equal((await db.query('select source from public.legal_acceptances')).rows[0].source,'authenticated_confirmation');
  });
  await t.test('previous legal versions are retained but do not authorize the current portal',async()=>{
   const id='10000000-0000-4000-8000-000000000006';await db.exec('reset role');
   await db.query('insert into auth.users(id,email,raw_user_meta_data) values($1,$2,$3)',[id,'previous@example.com',JSON.stringify({full_name:'Previous acceptance',birth_date:'1980-01-01',nif:'723456789'})]);
   await db.query("insert into public.legal_acceptances(user_id,terms_version,privacy_version,source) values($1,'2026-10-23.1','2026-10-23.1','registration')",[id]);
   await actor(ids.staff);const account=(await db.query('select public.approve_client($1,$2,2025) as id',[id,'Versioned account'])).rows[0].id;
   await actor(id);assert.equal((await db.query('select * from public.client_accounts where id=$1',[account])).rows.length,0);
   await db.query("select public.record_legal_acceptance('2026-10-28.1','2026-10-28.1')");assert.equal((await db.query('select * from public.client_accounts where id=$1',[account])).rows.length,1);
   assert.deepEqual((await db.query('select terms_version from public.legal_acceptances order by terms_version')).rows.map(r=>r.terms_version),['2026-10-23.1','2026-10-28.1']);
  });
  await t.test('client reads own tenant and cannot self-promote or grant modules',async()=>{
   await actor(ids.a);assert.equal((await db.query('select * from public.client_accounts')).rows.length,1);
   assert.equal((await db.query('select * from public.people where account_id=$1',[b])).rows.length,0);
   await assert.rejects(db.query('insert into public.staff_users(user_id) values($1) on conflict do nothing',[ids.a]));
   assert.equal((await db.query('update public.account_access set business=true where user_id=$1 returning *',[ids.a])).rows.length,0);
   await assert.rejects(db.query('select public.add_case_person($1,$2,$3,$4,$5,$6,$7,true)',[b,cb,'Other','1990-01-01','444444444','conjuge','']));
  });
  await t.test('profile data is not a source of professional privileges',async()=>{
   await actor(ids.a);assert.equal((await db.query('select public.is_staff() as staff')).rows[0].staff,false);
   assert.equal((await db.query('select * from public.profiles')).rows.length,1);
   await assert.rejects(db.query('insert into public.progress_events(account_id,case_id,title,body) values($1,$2,$3,$4)',[a,ca,'Spoof','Not allowed']));
   assert.equal((await db.query("update public.irs_cases set status='submitted' where id=$1 returning *",[ca])).rows.length,0);
  });
  let person;
  await t.test('2FA flag creates one staff-only alert and repeated saves do not duplicate it',async()=>{
   await actor(ids.a);person=(await db.query('select public.add_case_person($1,$2,$3,$4,$5,$6,$7,true) as id',[a,ca,'Family A','1990-01-01','555555555','conjuge','member@example.com'])).rows[0].id;
   await db.query('update public.people set tax_two_factor=true where id=$1',[person]);assert.equal((await db.query('select * from public.task_alerts')).rows.length,0);
   await actor(ids.staff);assert.equal((await db.query('select * from public.task_alerts where person_id=$1',[person])).rows.length,1);
  });
  await t.test('cross-case associations and missing personal context are rejected',async()=>{
   await actor(ids.staff);
   await assert.rejects(db.query("insert into public.income_records(account_id,case_id,category,person_id,title,mode) values($1,$2,'employment',$3,'Wrong','documents')",[a,ca,pb]));
   await assert.rejects(db.query("insert into public.income_records(account_id,case_id,category,title,mode) values($1,$2,'employment','Missing','documents')",[a,ca]));
   await actor(ids.a);const asset=(await db.query("insert into public.property_assets(account_id,case_id,label) values($1,$2,'Imóvel 1') returning id",[a,ca])).rows[0].id;
   await db.query("insert into public.income_records(account_id,case_id,category,property_id,person_id,title,mode) values($1,$2,'property_sale',$3,$4,'Sale','documents')",[a,ca,asset,pa]);
  });
  await t.test('message authors cannot be forged',async()=>{
   await actor(ids.a);await assert.rejects(db.query('insert into public.messages(account_id,case_id,author_id,body) values($1,$2,$3,$4)',[a,ca,ids.b,'Forged']));
   await db.query('insert into public.messages(account_id,case_id,body) values($1,$2,$3)',[a,ca,'Own message']);await actor(ids.b);assert.equal((await db.query('select * from public.messages')).rows.length,0);
  });
  const doc='20000000-0000-4000-8000-000000000001',path=a+'/'+ca+'/'+doc;
  await t.test('private files require authorized metadata, upload state and tenant',async()=>{
   await actor(ids.a);
   await assert.rejects(db.query("insert into public.documents(id,account_id,case_id,kind,file_name,storage_path,mime_type,file_size,state) values($1,$2,$3,'Other','file.pdf',$4,'application/pdf',10,'reviewed')",[doc,a,ca,path]));
   await db.query("insert into public.documents(id,account_id,case_id,kind,file_name,storage_path,mime_type,file_size) values($1,$2,$3,'Other','file.pdf',$4,'application/pdf',10)",[doc,a,ca,path]);
   await assert.rejects(db.query("insert into storage.objects(bucket_id,name) values('irs-documents','unregistered-path')"));
   await db.query("insert into storage.objects(bucket_id,name) values('irs-documents',$1)",[path]);assert.equal((await db.query('select * from storage.objects')).rows.length,0);
   await db.query("update public.documents set state='uploaded' where id=$1",[doc]);assert.equal((await db.query('select * from storage.objects')).rows.length,1);
   await actor(ids.b);assert.equal((await db.query('select * from public.documents')).rows.length,0);assert.equal((await db.query('select * from storage.objects')).rows.length,0);
  });
  await t.test('review locks collection; staff progress update is atomic',async()=>{
   await actor(ids.a);await assert.rejects(db.query('select public.submit_case($1,$2)',[a,ca]));await actor(ids.staff);await db.query("update public.irs_cases set status='validation' where id=$1",[ca]);await actor(ids.a);
   await assert.rejects(db.query("insert into public.income_records(account_id,case_id,category,person_id,title,mode) values($1,$2,'employment',$3,'Locked','documents')",[a,ca,pa]));
   await db.query('insert into public.messages(account_id,case_id,body) values($1,$2,$3)',[a,ca,'Clarification while under review']);
   await actor(ids.staff);await assert.rejects(db.query('select public.publish_case_progress($1,$2,$3,$4,$5)',[a,ca,'Bad update','Body','invalid']));assert.equal((await db.query('select * from public.progress_events')).rows.length,0);
   await assert.rejects(db.query('select public.publish_case_progress($1,$2,$3,$4,$5)',[a,ca,'Reopened','Please complete documents','collecting']));await db.query('select public.publish_case_progress($1,$2,$3,$4,$5)',[a,ca,'Returned','Please complete documents','returned']);assert.equal((await db.query('select status from public.irs_cases where id=$1',[ca])).rows[0].status,'returned');await actor(ids.a);assert.equal((await db.query('select * from public.progress_events')).rows.length,1);
  });
  await t.test('invitation requests do not create broad family access',async()=>{
   await actor(ids.a);await db.query('insert into public.invitation_requests(account_id,person_id,email) values($1,$2,$3)',[a,person,'member@example.com']);
   await actor(ids.member);assert.equal((await db.query('select * from public.client_accounts')).rows.length,0);
   await db.exec('reset role');await db.query("insert into public.account_access(account_id,user_id,role,irs) values($1,$2,'member',true)",[a,ids.member]);await actor(ids.member);assert.equal((await db.query('select * from public.people')).rows.length,0);
  });
  await t.test('financial records do not leak across accounts',async()=>{
   await db.exec('reset role');await db.query("insert into public.invoices(account_id,reference,issued_at,total) values($1,'FT1','2026-10-23',100)",[a]);await actor(ids.b);assert.equal((await db.query('select * from public.invoices')).rows.length,0);
  });
  await t.test('approval retries preserve accounts, grants and existing annual data',async()=>{
   await actor(ids.staff);
   const before=(await db.query('select count(*) as n from public.client_accounts')).rows[0].n;
   assert.equal((await db.query('select public.approve_client($1,$2,2026) as id',[ids.a,'Retry name'])).rows[0].id,a);
   assert.equal((await db.query('select count(*) as n from public.client_accounts')).rows[0].n,before);
   assert.equal((await db.query('select count(*) as n from public.people where account_id=$1 and nif=$2',[a,'123456789'])).rows[0].n,1);
   assert.equal((await db.query('select count(*) as n from public.irs_cases where account_id=$1',[a])).rows[0].n,1);
   assert.equal((await db.query('select name from public.client_accounts where id=$1',[a])).rows[0].name,'Account A');
   await assert.rejects(db.query('select public.approve_client($1,$2,2101)',[ids.a,'Bad year']));
   await actor(ids.a);await assert.rejects(db.query('select public.approve_client($1,$2,2025)',[ids.a,'Self approve']));
  });
  let nextCase;
  await t.test('staff opens a new annual case once without copying fiscal records',async()=>{
   await actor(ids.a);await assert.rejects(db.query('select public.create_irs_case($1,2026)',[a]));
   await actor(ids.staff);
   await assert.rejects(db.query('select public.create_irs_case($1,null)',[a]));
   await assert.rejects(db.query('select public.create_irs_case($1,1999)',[a]));
   await assert.rejects(db.query('select public.create_irs_case($1,2026)',[ids.a]));
   nextCase=(await db.query('select public.create_irs_case($1,2026) as id',[a])).rows[0].id;
   assert.equal((await db.query('select public.create_irs_case($1,2026) as id',[a])).rows[0].id,nextCase);
   assert.equal((await db.query('select public.create_irs_case($1,2025) as id',[a])).rows[0].id,ca);
   assert.equal((await db.query('select count(*) as n from public.irs_cases where account_id=$1',[a])).rows[0].n,2);
   assert.equal((await db.query('select status from public.irs_cases where id=$1',[nextCase])).rows[0].status,'collecting');
   assert.equal((await db.query('select person_id from public.case_people where case_id=$1',[nextCase])).rows[0].person_id,pa);
   for(const table of ['income_records','property_assets','documents','messages','progress_events'])assert.equal((await db.query(`select count(*) as n from public.${table} where case_id=$1`,[nextCase])).rows[0].n,0);
   assert.equal((await db.query('select count(*) as n from public.income_records where case_id=$1',[ca])).rows[0].n,1);
   await actor(ids.a);assert.equal((await db.query('select count(*) as n from public.irs_cases')).rows[0].n,2);
  });
  await t.test('existing household people can be linked for another year without changing old relationships',async()=>{
   await actor(ids.a);
   await assert.rejects(db.query('select public.link_case_person($1,$2,$3,$4)',[a,nextCase,pb,'conjuge']));
   await assert.rejects(db.query('select public.link_case_person($1,$2,$3,$4)',[b,cb,person,'conjuge']));
   await assert.rejects(db.query('select public.link_case_person($1,$2,$3,$4)',[a,nextCase,person,'titular']));
   await db.query('select public.link_case_person($1,$2,$3,$4)',[a,nextCase,person,'outro']);
   await db.query('select public.link_case_person($1,$2,$3,$4)',[a,nextCase,person,'outro']);
   await assert.rejects(db.query('select public.link_case_person($1,$2,$3,$4)',[a,nextCase,person,'conjuge']));
   assert.equal((await db.query('select count(*) as n from public.case_people where case_id=$1',[nextCase])).rows[0].n,2);
   assert.equal((await db.query('select relationship from public.case_people where case_id=$1 and person_id=$2',[ca,person])).rows[0].relationship,'conjuge');
   await assert.rejects(db.query('select public.submit_case($1,$2)',[a,nextCase]));await actor(ids.staff);await db.query("update public.irs_cases set status='validation' where id=$1",[nextCase]);await actor(ids.a);
   await assert.rejects(db.query('select public.link_case_person($1,$2,$3,$4)',[a,nextCase,person,'outro']));
  });
  await t.test('suspension and revoked IRS grants cannot be undone by an approval retry',async()=>{
   await actor(ids.staff);await db.query("update public.client_accounts set status='suspended' where id=$1",[a]);
   assert.equal((await db.query('select public.approve_client($1,$2,2027) as id',[ids.a,'Retry'])).rows[0].id,a);
   await assert.rejects(db.query('select public.create_irs_case($1,2027)',[a]));
   assert.equal((await db.query('select status from public.client_accounts where id=$1',[a])).rows[0].status,'suspended');
   await db.query("update public.client_accounts set status='active' where id=$1",[a]);
   await db.query('update public.account_access set irs=false where account_id=$1 and user_id=$2',[a,ids.a]);
   await db.query('select public.approve_client($1,$2,2027)',[ids.a,'Retry']);
   await assert.rejects(db.query('select public.create_irs_case($1,2027)',[a]));
   assert.equal((await db.query('select irs from public.account_access where account_id=$1 and user_id=$2',[a,ids.a])).rows[0].irs,false);
   await db.query('update public.account_access set irs=true where account_id=$1 and user_id=$2',[a,ids.a]);
  });
  await t.test('pre-existing ambiguous annual cases are preserved and require explicit review',async()=>{
   await db.exec('reset role');
   const duplicate=(await db.query('insert into public.irs_cases(account_id,tax_year) values($1,2025) returning id',[b])).rows[0].id;
   await actor(ids.staff);await assert.rejects(db.query('select public.create_irs_case($1,2025)',[b]));
   assert.equal((await db.query('select count(*) as n from public.irs_cases where account_id=$1 and tax_year=2025',[b])).rows[0].n,2);
   await db.exec('reset role');await db.query('delete from public.irs_cases where id=$1',[duplicate]);
  });
  await t.test('multiple existing owner accounts are never merged or approved arbitrarily',async()=>{
   await db.exec('reset role');
   await db.query("insert into public.account_access(account_id,user_id,role,irs) values($1,$2,'owner',true)",[a,ids.b]);
   await actor(ids.staff);await assert.rejects(db.query('select public.approve_client($1,$2,2027)',[ids.b,'Ambiguous']));
   await assert.rejects(db.query('select public.create_irs_case($1,2027)',[a]));
   assert.equal((await db.query(`select count(*) as n from public.account_access where user_id=$1 and role='owner'`,[ids.b])).rows[0].n,2);
   await db.exec('reset role');await db.query('delete from public.account_access where account_id=$1 and user_id=$2',[a,ids.b]);
  });
  await t.test('revocation blocks reads and subsequent private object access',async()=>{
   await actor(ids.staff);await db.query('update public.account_access set active=false where account_id=$1 and user_id=$2',[a,ids.a]);await actor(ids.a);assert.equal((await db.query('select * from public.client_accounts')).rows.length,0);assert.equal((await db.query('select * from public.documents')).rows.length,0);assert.equal((await db.query('select * from storage.objects')).rows.length,0);
   await actor(ids.staff);await db.query('select public.approve_client($1,$2,2028)',[ids.a,'Retry after revocation']);await assert.rejects(db.query('select public.create_irs_case($1,2028)',[a]));assert.equal((await db.query('select active from public.account_access where account_id=$1 and user_id=$2',[a,ids.a])).rows[0].active,false);
  });
 }finally{await db.close();}
});
