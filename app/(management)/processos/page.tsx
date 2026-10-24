import {session} from '@/lib/auth';
import ManagementShell from '@/components/management-shell';
import PortalLink from '@/components/portal-link';
import {states} from '@/lib/data';
export default async function Processes({searchParams}:{searchParams:Promise<{q?:string;estado?:string;pagina?:string}>}){
 const {client}=await session(),params=await searchParams;
 const page=Math.max(0,Number.parseInt(params.pagina||'0',10)||0),q=(params.q||'').trim().slice(0,100);
 let request=client.from('irs_cases').select('id,account_id,status,created_at,client:client_accounts!inner(name)',{count:'exact'}).eq('campaign',2026).order('created_at',{ascending:false}).range(page*40,page*40+39);
 if(q)request=request.ilike('client_accounts.name','%'+q.replace(/[\\%_]/g,'\\$&')+'%');
 if(params.estado&&Object.hasOwn(states,params.estado))request=request.eq('status',params.estado);
 const {data,error,count}=await request;
 return <ManagementShell title="IRS 2026"><section className="panel"><form method="get" className="field-grid"><label>Cliente<input name="q" defaultValue={q}/></label><label>Estado<select name="estado" defaultValue={params.estado||''}><option value="">Todos</option>{Object.entries(states).map(([key,label])=><option key={key} value={key}>{label}</option>)}</select></label><button>Filtrar processos</button></form></section><section className="panel"><h2>{count??0} processos</h2>{error?<p>Não foi possível carregar os processos. Confirme a atualização SQL.</p>:!data?.length?<p>Ainda não existem processos com estes critérios.</p>:data.map(row=><article className="record" key={row.id}><div><h3>{(row.client as unknown as {name:string})?.name||'Cliente'}</h3><span className="badge">{states[row.status]}</span></div><PortalLink href={`/irs?conta=${row.account_id}&processo=${row.id}`}>Acompanhar processo →</PortalLink></article>)}</section><div className="module-links">{page>0&&<PortalLink href={`/processos?pagina=${page-1}&q=${encodeURIComponent(q)}&estado=${params.estado||''}`}>← Anterior</PortalLink>}{(page+1)*40<(count||0)&&<PortalLink href={`/processos?pagina=${page+1}&q=${encodeURIComponent(q)}&estado=${params.estado||''}`}>Seguinte →</PortalLink>}</div></ManagementShell>;
}
