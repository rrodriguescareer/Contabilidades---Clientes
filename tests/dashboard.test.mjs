import test from 'node:test';
import assert from 'node:assert/strict';
import {loadCaseData,loadManagementData} from '../lib/dashboard-data.ts';
function mock(){
 const calls=[];
 const client={from(table){const call={table,options:null,filters:[]};const chain={
 select(columns,options){call.options=options;call.columns=columns;return chain;},
 eq(...args){call.filters.push(['eq',...args]);return chain;},neq(...args){call.filters.push(['neq',...args]);return chain;},
 is(...args){call.filters.push(['is',...args]);return chain;},order(){return chain;},limit(){return chain;},
 then(resolve,reject){calls.push(call);return Promise.resolve({data:[],error:null,count:call.options?.head?0:null}).then(resolve,reject);},
 };return chain;}};return {client,calls};
}
test('opening messages or progress does not request documents, invoices or income records',async()=>{
 for(const [view,table]of [['mensagens','messages'],['progresso','progress_events']]){
  const {client,calls}=mock();await loadCaseData(client,view,'account-a','case-a');
  assert.deepEqual(calls.map(c=>c.table),[table]);assert.deepEqual(calls[0].filters,[['eq','case_id','case-a']]);
 }
});
test('overview requests counts only, without downloading household or document rows',async()=>{
 const {client,calls}=mock();await loadCaseData(client,'resumo','account-a','case-a');
 assert.equal(calls.length,3);for(const call of calls)assert.equal(call.options.head,true);
 assert.ok(calls.find(c=>c.table==='documents').filters.some(f=>f[0]==='neq'&&f[1]==='state'&&f[2]==='pending'));
});
test('editing and billing load only their relevant data and preserve checkout locking',async()=>{
 const plans={agregado:['case_people','people','household_invitations','irs_checkouts'],rendimentos:['case_people','people','property_assets','income_records','irs_checkouts'],documentos:['income_records','documents','irs_checkouts'],faturacao:['invoices','payments','irs_checkouts'],pagamento:['irs_checkouts']};
 for(const [view,tables]of Object.entries(plans)){const {client,calls}=mock();await loadCaseData(client,view,'account-a','case-a');assert.deepEqual(calls.map(c=>c.table),tables,view);}
});
test('management-only datasets are not loaded for client accounts or unrelated modules',async()=>{
 let fixture=mock();await loadManagementData(fixture.client,'clientes',false);assert.equal(fixture.calls.length,0);
 fixture=mock();await loadManagementData(fixture.client,'mensagens',true);assert.equal(fixture.calls.length,0);
 fixture=mock();await loadCaseData(fixture.client,'resumo','account-a','case-a',true);assert.equal(fixture.calls.length,0);
 fixture=mock();await loadManagementData(fixture.client,'resumo',true);assert.equal(fixture.calls.length,2);assert.ok(fixture.calls.every(c=>c.options.head));
 fixture=mock();await loadCaseData(fixture.client,'agregado','account-a','');assert.equal(fixture.calls.length,0);
});
