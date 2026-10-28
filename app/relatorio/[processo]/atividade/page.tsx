import { notFound } from 'next/navigation';
import { uuid } from '@/lib/data';
import { lerRelatorio, lerStripe, type DetalheStripe } from '@/lib/relatorio-atividade';
import { Folha } from './folha';

export const metadata = { title: 'Relatório de atividade' };
export const dynamic = 'force-dynamic';

/* Relatório de atividade e prova de prestação de serviço.
   Feito para responder a uma contestação de pagamento: identifica as partes,
   o serviço e o pagamento (com o que o Stripe registou), e lista por ordem
   cronológica cada passo dado na plataforma, com data e hora ao segundo.
   Imprime-se ou guarda-se em PDF pelo browser e assina-se no fim. */
export default async function RelatorioDeAtividade({ params }: { params: Promise<{ processo: string }> }) {
  const { processo } = await params;
  if (!uuid(processo)) notFound();
  const dados = await lerRelatorio(processo);
  if (!dados?.processo) notFound();
  const pagos = dados.pagamentos.filter((k) => k.estado === 'paid' && k.sessao);
  const stripe = (await Promise.all(pagos.map((k) => lerStripe(String(k.sessao))))).filter(Boolean) as DetalheStripe[];
  return <Folha processo={processo} dados={dados} stripe={stripe} />;
}
