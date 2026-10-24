import {readFile,readdir,writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';

const directory=new URL('../supabase/migrations/',import.meta.url);
export async function buildInstallSql(){
 const names=(await readdir(directory)).filter(name=>/^\d+_.*\.sql$/.test(name)).sort();
 const parts=[];
 for(const name of names){
  const sql=await readFile(new URL(name,directory),'utf8');
  if((sql.match(/^begin;\s*$/gmi)||[]).length!==1||(sql.match(/^commit;\s*$/gmi)||[]).length!==1)throw new Error(`Unexpected transaction boundaries in ${name}`);
  parts.push(`-- Source: ${name}\n${sql.replace(/^begin;\s*$/gmi,'').replace(/^commit;\s*$/gmi,'').trim()}`);
 }
 return `-- INSTALACAO INICIAL: executar o ficheiro completo no SQL Editor do Supabase.
-- Gerado por npm run db:bundle. Inclui todas as migracoes, numa unica transacao.
-- Para uma instalacao existente, aplicar apenas as migracoes pendentes.
begin;
do $preflight$
declare existing_table text;
begin
 if to_regclass('auth.users') is null or to_regclass('storage.objects') is null then
  raise exception 'Abra o SQL Editor do projeto Supabase correto; faltam Auth ou Storage.';
 end if;
 select name into existing_table from unnest(array[
  'profiles','staff_users','client_accounts','account_access','people','irs_cases','case_people',
  'property_assets','income_records','documents','messages','progress_events','invoices','payments',
  'task_alerts','invitation_requests','legal_acceptances','management_audit','companies','company_users','household_invitations','discount_codes','irs_checkouts'
 ]) as tables(name) where to_regclass('public.'||name) is not null limit 1;
 if existing_table is not null then
  raise exception 'Ja existe public.%. A instalacao inicial foi interrompida sem alterar dados. Aplique apenas as migracoes pendentes.',existing_table;
 end if;
end $preflight$;

${parts.join('\n\n')}

commit;
select 'Instalacao concluida: estrutura IRS e Gestao criada.' as resultado;
`;
}

export async function buildUpgradeSql(){
 const names=['202610230005_accounts_and_management.sql','202610230006_checkout.sql','202610230007_document_deduplication.sql'];
 const parts=[];
 for(const name of names){
  const sql=await readFile(new URL(name,directory),'utf8');
  parts.push(`-- Source: ${name}\n${sql.replace(/^begin;\s*$/gmi,'').replace(/^commit;\s*$/gmi,'').trim()}`);
 }
 return `-- ATUALIZACAO 005–007: apenas para instalacoes que ja aplicaram 001–004.
-- Executar o ficheiro inteiro no SQL Editor. Nao repetir o instalador inicial.
begin;
do $preflight$
begin
 if to_regclass('public.profiles') is null or to_regclass('public.irs_cases') is null or to_regprocedure('public.create_irs_case(uuid,integer)') is null then
  raise exception 'Falta a instalacao 001–004. Numa base vazia, execute supabase/install.sql.';
 end if;
 if exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='onboarding_completed_at') then
  raise exception 'A migracao 005 ja foi aplicada. A atualizacao foi interrompida sem alterar dados; aplique apenas as migracoes ainda pendentes.';
 end if;
end $preflight$;
${parts.join('\n\n')}
commit;
select 'Atualizacao concluida: registo automatico, gestao, descontos, pagamentos e documentos.' as resultado;
`;
}

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 await writeFile(new URL('../supabase/install.sql',import.meta.url),await buildInstallSql());
 await writeFile(new URL('../supabase/upgrade-005-007.sql',import.meta.url),await buildUpgradeSql());
 console.log('supabase/install.sql e supabase/upgrade-005-007.sql atualizados.');
}
