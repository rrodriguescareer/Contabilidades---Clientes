import { AuthShell } from '@/lib/auth-view';
import { recover } from '@/lib/auth-actions';
export const dynamic='force-dynamic';
export default async function Recover({searchParams}:{searchParams:Promise<{erro?:string}>}){const {erro}=await searchParams;return <AuthShell title="Recuperar acesso" description="Receba as instruções no seu email." error={erro}><form action={recover}><label>Email<input type="email" name="email" autoComplete="email" required/></label><button className="primary">Enviar instruções</button></form></AuthShell>;}
