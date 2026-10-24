import Link from 'next/link';
import { Submeter } from '@/components/forms';
import { EcraAutenticacao } from '@/lib/auth-view';
import { recover } from '@/lib/auth-actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Recuperar acesso' };

export default async function Recuperar({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  const parametros = await searchParams;
  return (
    <EcraAutenticacao
      titulo="Recuperar o acesso."
      descricao="Enviamos uma ligação para definir uma nova palavra-passe."
      erro={parametros.erro}
      mensagem={parametros.mensagem}
      rodape={<Link href="/entrar">Voltar a entrar</Link>}
    >
      <form action={recover}>
        <label className="campo">
          <span>Email</span>
          <input name="email" type="email" className="entrada" autoComplete="email" required maxLength={254} />
        </label>
        <Submeter aDecorrer="A enviar…">Enviar ligação</Submeter>
      </form>
    </EcraAutenticacao>
  );
}
