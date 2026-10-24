'use client';
import {useTransition} from 'react';
import {useRouter} from 'next/navigation';
import type {Account,Process} from '@/lib/data';
export default function ContextSelector({accounts,account,view}:{accounts:Account[];cases:Process[];account:string;caseId:string;view:string}){
 const router=useRouter(),[pending,startTransition]=useTransition();
 return accounts.length>1?<div className="context-select" aria-busy={pending}><label>Cliente<select value={account} disabled={pending} onChange={e=>startTransition(()=>router.push(`/irs?view=${view}&conta=${e.target.value}`))}>{accounts.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select></label>{pending&&<span className="navigation-spinner" role="status" aria-label="A mudar de cliente"/>}</div>:null;
}
