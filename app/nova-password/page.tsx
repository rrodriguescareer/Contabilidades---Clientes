import { AuthShell } from '@/lib/auth-view';
import { changePassword } from '@/lib/auth-actions';
export const dynamic='force-dynamic';
export default async function NewPassword({searchParams}:{searchParams:Promise<{erro?:string}>}){const {erro}=await searchParams;return <AuthShell title="Nova palavra-passe" description="Utilize a ligação de recuperação recebida por email." error={erro}><form action={changePassword}><label>Nova palavra-passe<input type="password" name="password" autoComplete="new-password" minLength={12} maxLength={128} required/></label><button className="primary">Guardar palavra-passe</button></form></AuthShell>;}
