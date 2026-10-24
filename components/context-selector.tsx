'use client';
import {useTransition} from 'react';
import {useRouter} from 'next/navigation';
import type {Account,Process} from '@/lib/data';
export default function ContextSelector({accounts,cases,account,caseId,view}:{accounts:Account[];cases:Process[];account:string;caseId:string;view:string}){
 const router=useRouter(),[pending,startTransition]=useTransition();
 function select(nextAccount:string,nextCase?:string){const params=new URLSearchParams({view,conta:nextAccount});if(nextCase)params.set('processo',nextCase);startTransition(()=>router.push('/app?'+params));}
 return <div className="context-select" aria-busy={pending}><label>Conta<select value={account} disabled={pending} onChange={e=>select(e.target.value)}>{accounts.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select></label><label>Processo<select value={caseId} disabled={pending||cases.length===0} onChange={e=>select(account,e.target.value)}>{cases.length===0&&<option value="">Sem processo</option>}{cases.map(c=><option key={c.id} value={c.id}>{c.tax_year} · {c.label}</option>)}</select></label>{pending&&<span className="navigation-spinner" role="status" aria-label="A mudar de processo"/>}</div>;
}
