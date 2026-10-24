import Link from 'next/link';
import { Submeter } from '@/components/forms';
import { EcraAutenticacao } from '@/lib/auth-view';
import { signIn } from '@/lib/auth-actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Entrar' };

export default async function Entrar({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string; destino?: string }> }) {
  const parametros = await searchParams;
  return (
    <EcraAutenticacao
      titulo="Gestão de clientes."
      descricao="Acesso reservado ao contabilista certificado."
      erro={parametros.erro}
      mensagem={parametros.mensagem}
      rodape={<Link href="/recuperar">Esqueci-me da palavra-passe</Link>}
    >
      <form action={signIn}>
        <input type="hidden" name="destino" value={parametros.destino ?? ''} />
        <label className="campo">
          <span>Email</span>
          <input name="email" type="email" className="entrada" autoComplete="email" required maxLength={254} />
        </label>
        <label className="campo">
          <span>Palavra-passe</span>
          <input name="password" type="password" className="entrada" autoComplete="current-password" required maxLength={128} />
        </label>
        <Submeter aDecorrer="A entrar…">Entrar</Submeter>
      </form>
    </EcraAutenticacao>
  );
}
