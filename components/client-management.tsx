import Link from 'next/link';
import { approveClient,createAnnualCase,updateAccess } from '@/lib/actions';
import type { Account,Profile } from '@/lib/data';
import { Submit } from './forms';

export type Access={account_id:string;user_id:string;role:string;active:boolean;irs:boolean;business:boolean};
export default function ClientManagement({accounts,profiles,accesses,userId,selectedAccount}:{accounts:Account[];profiles:Profile[];accesses:Access[];userId:string;selectedAccount:string}){
 const clients=profiles.filter(p=>p.id!==userId);
 const owners=(id:string)=>accesses.filter(a=>a.user_id===id&&a.role==='owner');
 const pending=clients.filter(p=>owners(p.id).length===0);
 const approved=clients.filter(p=>owners(p.id).length>0);
 const eligible=accounts.filter(a=>a.status==='active'&&accesses.filter(x=>x.account_id===a.id&&x.role==='owner'&&x.active&&x.irs).length===1);
 const selected=eligible.some(a=>a.id===selectedAccount)?selectedAccount:eligible[0]?.id;
 const year=new Date().getFullYear()-1;
 return <>
  <section className="panel"><h2>Registos por aprovar</h2><p>A aprovação cria a conta, o acesso IRS, o primeiro processo anual e o titular numa só operação.</p>
   {pending.length===0?<p className="empty">Sem registos por aprovar.</p>:pending.map(p=><details key={p.id}><summary>{p.full_name} · {p.email}</summary>
    {p.birth_date&&p.nif?<form action={approveClient}><input type="hidden" name="user_id" value={p.id}/><div className="field-grid"><label>Nome da conta<input name="name" defaultValue={p.full_name} required maxLength={200}/></label><label>Ano dos rendimentos<input type="number" name="year" min={2000} max={2100} defaultValue={year} required/></label></div><Submit>Criar conta e atribuir IRS</Submit></form>:<p>Faltam NIF ou data de nascimento. Confirme os dados do registo antes da aprovação.</p>}
   </details>)}
  </section>
  <section className="panel"><h2>Clientes com conta</h2>{approved.length===0?<p className="empty">Ainda não existem contas aprovadas.</p>:approved.map(p=><article className="record" key={p.id}><div><h3>{p.full_name}</h3><p>{p.email}</p>{owners(p.id).map(a=><p key={a.account_id}><Link href={`/app?conta=${a.account_id}&view=resumo`}>{accounts.find(c=>c.id===a.account_id)?.name||'Abrir conta'} →</Link><small> · {a.active&&a.irs?'Acesso IRS ativo':'Acesso IRS desativado'}{accounts.find(c=>c.id===a.account_id)?.status!=='active'?' · Conta suspensa ou encerrada':''}</small></p>)}</div></article>)}</section>
  <section className="panel"><h2>Abrir um ano de IRS</h2><p>Utilize a conta existente para abrir outro ano. Se o processo desse ano já existir, será aberto sem criar um duplicado.</p>
   {eligible.length===0?<p className="empty">É necessária uma conta ativa com um titular com acesso IRS ativo.</p>:<form action={createAnnualCase}><div className="field-grid"><label>Conta-cliente<select name="account" defaultValue={selected} required>{eligible.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select></label><label>Ano dos rendimentos<input name="year" type="number" min={2000} max={2100} defaultValue={year} required/></label></div><Submit>Abrir processo anual</Submit><p className="fine">Só o titular fica associado inicialmente. Confirme os restantes membros para este ano; rendimentos, imóveis e documentos começam vazios.</p></form>}
  </section>
  <section className="panel"><h2>Acessos por cliente</h2>{accesses.length===0?<p className="empty">Ainda não existem acessos atribuídos.</p>:accesses.map(a=><form key={a.account_id+a.user_id} action={updateAccess} className="access-row"><input type="hidden" name="account" value={a.account_id}/><input type="hidden" name="user" value={a.user_id}/><div><strong>{accounts.find(c=>c.id===a.account_id)?.name}</strong><small>{profiles.find(p=>p.id===a.user_id)?.email}</small></div><label className="check"><input type="checkbox" name="active" defaultChecked={a.active}/>Ativo</label><label className="check"><input type="checkbox" name="irs" defaultChecked={a.irs}/>IRS</label><label className="check"><input type="checkbox" name="business" defaultChecked={a.business}/>Empresas</label><Submit>Guardar</Submit></form>)}<p className="fine">A concessão Empresas fica registada; a plataforma de empresas ainda não foi implementada. Contas de familiares continuam sem acesso fiscal até existir autorização individual.</p></section>
 </>;
}
