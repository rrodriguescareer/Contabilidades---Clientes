import { session } from '@/lib/auth';
import { carregarGabinete } from '@/lib/irs-actions';
import { origemDasCredenciais, temCredenciais } from '@/lib/cegid';
import { uuid } from '@/lib/data';
import { ConsolaIrs } from '@/components/irs/consola';

export const metadata = { title: 'Gabinete IRS' };
export const dynamic = 'force-dynamic';

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };

const VISTAS = ['fila', 'mensagens', 'pagamentos', 'alertas', 'integracoes'];

/** O gabinete do IRS: a fila de trabalho, as conversas, os pagamentos e os
    alertas — e, com ?processo=, o processo aberto. Um pedido à base por ecrã. */
export default async function GabineteIrs({ searchParams }: Props) {
  await session();
  const procura = await searchParams;
  const texto = (k: string) => (typeof procura[k] === 'string' ? (procura[k] as string) : '');

  const pedida = texto('separador');
  const vista = VISTAS.includes(pedida) ? pedida : 'fila';
  const id = texto('processo');

  if (uuid(id)) {
    const { dados } = await carregarGabinete('processo', id);
    return (
      <ConsolaIrs vista={vista} dados={null} aba={texto('aba') || undefined}
                  processo={dados && !dados.erro ? { id, dados } : null}
                  cegidConfigurado={false} cegidOrigem="nenhuma" />
    );
  }

  const [{ dados }, configurado, origem] = await Promise.all([
    vista === 'integracoes' ? Promise.resolve({ dados: { vista } }) : carregarGabinete(vista, null),
    vista === 'integracoes' ? temCredenciais() : Promise.resolve(false),
    vista === 'integracoes' ? origemDasCredenciais() : Promise.resolve('nenhuma' as const),
  ]);

  return (
    <ConsolaIrs vista={vista} dados={dados as never} processo={null}
                cegidConfigurado={configurado} cegidOrigem={origem} />
  );
}
