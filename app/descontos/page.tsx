import {session} from '@/lib/auth';
import ManagementShell from '@/components/management-shell';
import {Submit} from '@/components/forms';
import {createDiscount,toggleDiscount} from '@/lib/management-actions';
export const dynamic='force-dynamic';
export default async function Discounts({searchParams}:{searchParams:Promise<{erro?:string;mensagem?:string}>}){
 const {client}=await session(),params=await searchParams;
 const [{data:codes,error},{data:uses}]=await Promise.all([
 client.from('discount_codes').select('*').order('created_at',{ascending:false}),
 client.from('irs_checkouts').select('discount_id,state').in('state',['creating','pending','unknown','paid']),
 ]);
 return <ManagementShell title="Códigos de desconto" error={params.erro} message={params.mensagem}><section className="panel"><h2>Criar código</h2><form action={createDiscount}><div className="field-grid"><label>Código<input name="code" pattern="[A-Za-z0-9_-]{3,40}" maxLength={40} required/></label><label>Tipo<select name="kind"><option value="percentage">Percentagem (%)</option><option value="fixed">Valor fixo (€)</option></select></label><label>Valor<input name="value" type="number" min="0.01" step="0.01" required/></label><label>Email do cliente (opcional)<input name="email" type="email" maxLength={254}/></label><label>Início (UTC, opcional)<input name="starts_at" type="datetime-local"/></label><label>Fim (UTC, opcional)<input name="ends_at" type="datetime-local"/></label><label>Máximo de utilizações (opcional)<input name="max_uses" type="number" min="1" step="1"/></label></div><Submit>Criar código</Submit><p className="fine">As restrições combinam-se. Os pagamentos pendentes reservam uma utilização, evitando ultrapassar o limite.</p></form></section>
 <section className="panel"><h2>Códigos existentes</h2>{error?<p>Não foi possível carregar os códigos.</p>:codes?.map(c=><form action={toggleDiscount} className="access-row" key={c.id}><input name="discount" type="hidden" value={c.id}/><input name="active" type="hidden" value={c.active?'false':'true'}/><div><strong>{c.code} · {c.kind==='percentage'?`${c.value/100}%`:`${(c.value/100).toFixed(2)} €`}</strong><small>{uses?.filter(u=>u.discount_id===c.id).length||0} utilizações ou reservas{c.max_uses?` / ${c.max_uses}`:''} · {c.active?'Ativo':'Inativo'}{c.allowed_user?' · Limitado a cliente':''}</small></div><Submit>{c.active?'Desativar':'Ativar'}</Submit></form>)}</section></ManagementShell>;
}
