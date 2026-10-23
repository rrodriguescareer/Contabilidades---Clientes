import Link from 'next/link';
import { AuthShell } from '@/lib/auth-view';
import { signIn } from '@/lib/auth-actions';
import { IS_MANAGEMENT } from '@/lib/app';
export const dynamic='force-dynamic';
export default async function Login({searchParams}:{searchParams:Promise<{erro?:string;mensagem?:string}>}){
 const params=await searchParams;
 return <AuthShell title="Bem-vindo de volta." description="Entre com a sua conta para continuar." error={params.erro} message={params.mensagem}><form action={signIn}><label>Email<input name="email" type="email" autoComplete="email" required maxLength={254}/></label><label>Palavra-passe<input name="password" type="password" autoComplete="current-password" required maxLength={128}/></label><button className="primary" type="submit">Entrar na plataforma →</button></form><div className="auth-links"><Link href="/recuperar">Recuperar acesso</Link>{!IS_MANAGEMENT&&<Link href="/registar">Criar conta</Link>}</div></AuthShell>;
}
