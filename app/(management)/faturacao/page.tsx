import {ownerSession} from '@/lib/auth';
import ManagementShell from '@/components/management-shell';
export default async function Billing(){
 const {client}=await ownerSession();
 const {data,error}=await client.from('invoices').select('id,reference,issued_at,total,currency,account_id,client:client_accounts(name),payments(amount)').order('issued_at',{ascending:false}).limit(100);
 const money=(v:number)=>new Intl.NumberFormat('pt-PT',{style:'currency',currency:'EUR'}).format(v);
 return <ManagementShell title="Faturação"><div className="alert">Consulte as faturas associadas às contas IRS. A emissão automática no Cegid e a faturação da plataforma Empresas serão ligadas quando essas integrações estiverem disponíveis.</div><section className="panel"><h2>Últimas faturas</h2>{error?<p>Não foi possível carregar as faturas.</p>:!data?.length?<p>Ainda não foram registadas faturas.</p>:data.map(row=>{const paid=(row.payments as {amount:number|string}[]).reduce((total,p)=>total+Number(p.amount),0);return <article className="record" key={row.id}><div><span className="badge">IRS</span><h3>{row.reference}</h3><p>{(row.client as unknown as {name:string})?.name} · {new Date(row.issued_at).toLocaleDateString('pt-PT')}</p></div><div><strong>{money(Number(row.total))}</strong><p>{paid>=Number(row.total)?'Pago':'Por liquidar'} · Recebido {money(paid)}</p></div></article>;})}</section></ManagementShell>;
}
