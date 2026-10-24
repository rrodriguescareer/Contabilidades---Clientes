import {session} from '@/lib/auth';
import ManagementShell from '@/components/management-shell';
import {resolveAlert} from '@/lib/actions';
import {Submit} from '@/components/forms';
import PortalLink from '@/components/portal-link';
export default async function Alerts({searchParams}:{searchParams:Promise<{erro?:string;mensagem?:string}>}){
 const {client}=await session(),params=await searchParams;
 const [{data:alerts,error},{data:invites,error:inviteError}]=await Promise.all([client.from('task_alerts').select('id,account_id,created_at,person:people(full_name)').is('resolved_at',null).order('created_at',{ascending:false}).limit(100),client.from('household_invitations').select('id,email,state,created_at').order('created_at',{ascending:false}).limit(100)]);
 return <ManagementShell title="Alertas e convites" error={params.erro} message={params.mensagem}><section className="panel"><h2>Duplo fator fiscal ativo</h2>{error?<p>Não foi possível carregar os alertas.</p>:!alerts?.length?<p>Sem alertas por acompanhar.</p>:alerts.map(row=><form action={resolveAlert} key={row.id} className="access-row"><input name="alert" value={row.id} type="hidden"/><div><strong>{(row.person as unknown as {full_name:string})?.full_name||'Pessoa do agregado'}</strong><p>2FA ativo no Portal das Finanças.</p><PortalLink href={`/irs?conta=${row.account_id}&view=agregado`}>Abrir agregado →</PortalLink></div><Submit>Marcar como acompanhado</Submit></form>)}</section><section className="panel"><h2>Convites do agregado</h2>{inviteError?<p>Não foi possível carregar os convites.</p>:!invites?.length?<p>Ainda sem convites.</p>:invites.map(row=><article key={row.id} className="record"><div><h3>{row.email}</h3><p>{new Date(row.created_at).toLocaleDateString('pt-PT')}</p></div><span className="badge">{({created:'Criado',sent:'Enviado',accepted:'Aceite',revoked:'Revogado',failed:'Envio falhou'} as Record<string,string>)[row.state]||row.state}</span></article>)}</section></ManagementShell>;
}
