import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

// Local PostgreSQL with minimal Supabase Auth/Storage fixtures. Never contacts Supabase.
const ids={staff:'10000000-0000-4000-8000-000000000001',a:'10000000-0000-4000-8000-000000000002',b:'10000000-0000-4000-8000-000000000003',member:'10000000-0000-4000-8000-000000000004'};
test('shared schema, database constraints and tenant isolation',async t=>{
 const db=new PGlite();
 try{
  await db.exec(`create role anon;create role authenticated;create schema auth;create schema storage;
  create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb not null default '{}');
  create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
  grant usage on schema auth,storage to authenticated;grant execute on function auth.uid() to authenticated;
  create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
  create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text not null);
  alter table storage.objects enable row level security;grant select,insert on storage.objects to authenticated;`);
  await db.exec(await readFile(new URL('../supabase/migrations/202610230001_core.sql',import.meta.url),'utf8'));
  for(const [name,id]of Object.entries(ids)) await db.query('insert into auth.users(id,email,raw_user_meta_data) values($1,$2,$3)',[id,name+'@example.com',JSON.stringify({full_name:'Test '+name,birth_date:'1980-01-01',nif:name==='a'?'123456789':name==='b'?'223456789':name==='member'?'323456789':'423456789'})]);
  await db.query('insert into public.staff_users(user_id) values($1)',[ids.staff]);
  const actor=async id=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
  await actor(ids.staff);
  const a=(await db.query('select public.approve_client($1,$2,2025) as id',[ids.a,'Account A'])).rows[0].id;
  const b=(await db.query('select public.approve_client($1,$2,2025) as id',[ids.b,'Account B'])).rows[0].id;
  const ca=(await db.query('select id from public.irs_cases where account_id=$1',[a])).rows[0].id;
  const cb=(await db.query('select id from public.irs_cases where account_id=$1',[b])).rows[0].id;
  const pa=(await db.query('select id from public.people where account_id=$1',[a])).rows[0].id;
  const pb=(await db.query('select id from public.people where account_id=$1',[b])).rows[0].id;
  await t.test('client reads own tenant and cannot self-promote or grant modules',async()=>{
   await actor(ids.a);assert.equal((await db.query('select * from public.client_accounts')).rows.length,1);
   assert.equal((await db.query('select * from public.people where account_id=$1',[b])).rows.length,0);
   await assert.rejects(db.query('insert into public.staff_users(user_id) values($1)',[ids.a]));
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
   await db.query("insert into public.income_records(account_id,case_id,category,property_id,title,mode) values($1,$2,'property_sale',$3,'Sale','documents')",[a,ca,asset]);
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
   await actor(ids.a);await db.query('select public.submit_case($1,$2)',[a,ca]);
   await assert.rejects(db.query("insert into public.income_records(account_id,case_id,category,person_id,title,mode) values($1,$2,'employment',$3,'Locked','documents')",[a,ca,pa]));
   await db.query('insert into public.messages(account_id,case_id,body) values($1,$2,$3)',[a,ca,'Clarification while under review']);
   await actor(ids.staff);await assert.rejects(db.query('select public.publish_case_progress($1,$2,$3,$4,$5)',[a,ca,'Bad update','Body','invalid']));assert.equal((await db.query('select * from public.progress_events')).rows.length,0);
   await db.query('select public.publish_case_progress($1,$2,$3,$4,$5)',[a,ca,'Reopened','Please complete documents','missing']);await actor(ids.a);assert.equal((await db.query('select * from public.progress_events')).rows.length,1);
  });
  await t.test('invitation requests do not create broad family access',async()=>{
   await actor(ids.a);await db.query('insert into public.invitation_requests(account_id,person_id,email) values($1,$2,$3)',[a,person,'member@example.com']);
   await actor(ids.member);assert.equal((await db.query('select * from public.client_accounts')).rows.length,0);
   await db.exec('reset role');await db.query("insert into public.account_access(account_id,user_id,role,irs) values($1,$2,'member',true)",[a,ids.member]);await actor(ids.member);assert.equal((await db.query('select * from public.people')).rows.length,0);
  });
  await t.test('financial records do not leak across accounts',async()=>{
   await db.exec('reset role');await db.query("insert into public.invoices(account_id,reference,issued_at,total) values($1,'FT1','2026-10-23',100)",[a]);await actor(ids.b);assert.equal((await db.query('select * from public.invoices')).rows.length,0);
  });
  await t.test('revocation blocks reads and subsequent private object access',async()=>{
   await actor(ids.staff);await db.query('update public.account_access set active=false where account_id=$1 and user_id=$2',[a,ids.a]);await actor(ids.a);assert.equal((await db.query('select * from public.client_accounts')).rows.length,0);assert.equal((await db.query('select * from public.documents')).rows.length,0);assert.equal((await db.query('select * from storage.objects')).rows.length,0);
  });
 }finally{await db.close();}
});
