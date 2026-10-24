'use client';
import {useEffect,useState,useTransition} from 'react';
import {useRouter} from 'next/navigation';
export default function LiveCaseUpdates({caseId,url,publishableKey}:{caseId:string;url:string;publishableKey:string}){
 const router=useRouter(),[connected,setConnected]=useState(false),[,startTransition]=useTransition();
 useEffect(()=>{
  let disposed=false,subscribed=false,lastRefresh=Date.now();let timer:ReturnType<typeof setTimeout>|undefined;
  let cleanup:(()=>void)|undefined;
  function refresh(){if(disposed||document.visibilityState!=='visible'||!navigator.onLine)return;lastRefresh=Date.now();startTransition(()=>router.refresh());}
  function schedule(){clearTimeout(timer);timer=setTimeout(refresh,400);}
  async function connect(){try{
   const {createBrowserClient}=await import('@supabase/ssr');if(disposed)return;
   const client=createBrowserClient(url,publishableKey);
   const channel=client.channel(`case-${caseId}`);
   for(const table of ['messages','progress_events','documents','irs_checkouts'])channel.on('postgres_changes',{event:'*',schema:'public',table,filter:`case_id=eq.${caseId}`},schedule);
   channel.subscribe(status=>{subscribed=status==='SUBSCRIBED';if(!disposed)setConnected(subscribed);});
   cleanup=()=>{void client.removeChannel(channel);};
  }catch{/* Periodic refresh remains available without Realtime configuration. */}}
  void connect();
  const interval=setInterval(()=>{if(Date.now()-lastRefresh>=(subscribed?60000:15000))refresh();},5000);
  const visible=()=>{if(document.visibilityState==='visible'&&Date.now()-lastRefresh>5000)refresh();};
  document.addEventListener('visibilitychange',visible);
  return()=>{disposed=true;clearTimeout(timer);clearInterval(interval);cleanup?.();document.removeEventListener('visibilitychange',visible);};
 },[caseId,url,publishableKey,router]);
 return <p className="live-status" role="status"><span className={connected?'live-dot connected':'live-dot'}/>{connected?'Atualização automática ativa':'Atualização automática periódica'}</p>;
}
