import type {SupabaseClient} from '@supabase/supabase-js';
type Result={data:unknown[]|null;error:unknown;count?:number|null};
const empty=():Result=>({data:[],error:null,count:0});
const views:Record<string,number[]>={
 agregado:[0,1,9,10],rendimentos:[0,1,2,3,10],documentos:[3,4,10],mensagens:[5],
 progresso:[6],faturacao:[7,8,10],pagamento:[10],
};
export async function loadCaseData(client:SupabaseClient,view:string,account:string,caseId:string,management=false){
 const tasks:PromiseLike<Result>[]=Array.from({length:11},()=>Promise.resolve(empty()));
 if(!caseId)return Promise.all(tasks);
 if(view==='resumo'&&!management){
  tasks[0]=client.from('case_people').select('person_id',{count:'exact',head:true}).eq('case_id',caseId);
  tasks[3]=client.from('income_records').select('id',{count:'exact',head:true}).eq('case_id',caseId);
  tasks[4]=client.from('documents').select('id',{count:'exact',head:true}).eq('case_id',caseId).neq('state','pending');
  return Promise.all(tasks);
 }
 for(const index of views[view]||[]){
  switch(index){
   case 0:tasks[index]=client.from('case_people').select('person_id,relationship').eq('case_id',caseId);break;
   case 1:tasks[index]=client.from('people').select('id,account_id,full_name,birth_date,nif,email,tax_two_factor').eq('account_id',account);break;
   case 2:tasks[index]=client.from('property_assets').select('id,label,description').eq('case_id',caseId);break;
   case 3:tasks[index]=client.from('income_records').select('id,title,category,person_id,property_id,mode,details').eq('case_id',caseId).order('created_at');break;
   case 4:tasks[index]=client.from('documents').select('id,kind,file_name,state,income_id,created_at').eq('case_id',caseId).order('created_at',{ascending:false});break;
   case 5:tasks[index]=client.from('messages').select('id,body,author_id,created_at').eq('case_id',caseId).order('created_at',{ascending:false}).limit(100);break;
   case 6:tasks[index]=client.from('progress_events').select('id,title,body,created_at').eq('case_id',caseId).order('created_at',{ascending:false}).limit(100);break;
   case 7:tasks[index]=client.from('invoices').select('id,reference,issued_at,due_at,total,currency').eq('account_id',account).order('issued_at',{ascending:false});break;
   case 8:tasks[index]=client.from('payments').select('invoice_id,amount,paid_at').eq('account_id',account);break;
   case 9:tasks[index]=client.from('household_invitations').select('id,person_id,email,state,expires_at,accepted_at').eq('account_id',account).order('created_at',{ascending:false});break;
   case 10:tasks[index]=client.from('irs_checkouts').select('id,state,amount_cents,paid_at,created_at').eq('case_id',caseId).order('created_at',{ascending:false});break;
  }
 }
 return Promise.all(tasks);
}
export async function loadManagementData(client:SupabaseClient,view:string,management:boolean){
 const tasks:PromiseLike<Result>[]=Array.from({length:5},()=>Promise.resolve(empty()));
 if(!management)return Promise.all(tasks);
 if(view==='resumo'){
  tasks[0]=client.from('profiles').select('id',{count:'exact',head:true});
  tasks[2]=client.from('task_alerts').select('id',{count:'exact',head:true}).is('resolved_at',null);
 }else if(view==='clientes'){
  tasks[0]=client.from('profiles').select('id,full_name,email,nif,birth_date,phone').order('created_at',{ascending:false});
  tasks[1]=client.from('account_access').select('account_id,user_id,role,active,irs,business');
 }else if(view==='alertas'){
  tasks[2]=client.from('task_alerts').select('id,account_id,person_id,created_at,person:people(full_name)').is('resolved_at',null).order('created_at',{ascending:false});
  tasks[4]=client.from('household_invitations').select('id,email,account_id,state').order('created_at',{ascending:false}).limit(100);
 }
 return Promise.all(tasks);
}
