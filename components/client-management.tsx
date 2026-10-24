import Link from 'next/link';
import { createAnnualCase,updateAccess } from '@/lib/actions';
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
  <section className="panel"><h2>Registos por completar</h2><p>O cliente confirma o email e completa os dados pessoais. A conta e o processo IRS são criados automaticamente, sem aprovação manual.</p>{pending.length===0?<p className="empty">Sem registos por completar.</p>:pending.map(p=><p key={p.id}>{p.full_name} · {p.email}</p>)}<Link href="/utilizadores">Consultar utilizadores e condições de acesso →</Link></section>
  <section className="panel"><h2>Clientes com conta</h2>{approved.length===0?<p className="empty">Ainda não existem contas aprovadas.</p>:approved.map(p=><article className="record" key={p.id}><div><h3>{p.full_name}</h3><p>{p.email}</p>{owners(p.id).map(a=><p key={a.account_id}><Link href={`/app?conta=${a.account_id}&view=resumo`}>{accounts.find(c=>c.id===a.account_id)?.name||'Abrir conta'} →</Link><small> · {a.active&&a.irs?'Acesso IRS ativo':'Acesso IRS desativado'}{accounts.find(c=>c.id===a.account_id)?.status!=='active'?' · Conta suspensa ou encerrada':''}</small></p>)}</div></article>)}</section>

  <section className="panel"><h2>Acessos por cliente</h2>{accesses.length===0?<p className="empty">Ainda não existem acessos atribuídos.</p>:accesses.map(a=><form key={a.account_id+a.user_id} action={updateAccess} className="access-row"><input type="hidden" name="account" value={a.account_id}/><input type="hidden" name="user" value={a.user_id}/><div><strong>{accounts.find(c=>c.id===a.account_id)?.name}</strong><small>{profiles.find(p=>p.id===a.user_id)?.email}</small></div><label className="check"><input type="checkbox" name="active" defaultChecked={a.active}/>Ativo</label><label className="check"><input type="checkbox" name="irs" defaultChecked={a.irs}/>IRS</label><label className="check"><input type="checkbox" name="business" defaultChecked={a.business}/>Empresas</label><Submit>Guardar</Submit></form>)}<p className="fine">A concessão Empresas fica registada; a plataforma de empresas ainda não foi implementada. Contas de familiares continuam sem acesso fiscal até existir autorização individual.</p></section>
 </>;
}
