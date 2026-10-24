import { Submeter } from '@/components/forms';
import { EcraAutenticacao } from '@/lib/auth-view';
import { changePassword } from '@/lib/auth-actions';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Nova palavra-passe' };

export default async function NovaPalavraPasse({ searchParams }: { searchParams: Promise<{ erro?: string }> }) {
  const { erro } = await searchParams;
  return (
    <EcraAutenticacao titulo="Defina a nova palavra-passe." descricao="Escolha uma que não use em mais lado nenhum." erro={erro}>
      <form action={changePassword}>
        <label className="campo">
          <span>Nova palavra-passe</span>
          <input name="password" type="password" className="entrada" autoComplete="new-password" minLength={12} maxLength={128} required />
        </label>
        <label className="campo">
          <span>Confirmar</span>
          <input name="confirmation" type="password" className="entrada" autoComplete="new-password" minLength={12} maxLength={128} required />
        </label>
        <Submeter>Guardar palavra-passe</Submeter>
      </form>
    </EcraAutenticacao>
  );
}
