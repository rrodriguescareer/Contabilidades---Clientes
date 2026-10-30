import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ownerSession as session } from '@/lib/auth';
import { Avisos } from '@/components/consola';
import { uuid } from '@/lib/data';
import { AbaAlertas, AbaAtividade, AbaDocumentos, AbaMensagens, AbaResumo } from './abas-gerais';
import { AbaFicha, AbaImpostos, AbaPessoal } from './abas-empresa';
import { mesesRecentes, PORTAL, type Contexto } from './comum';
import c from '../empresas.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Empresa' };

type Ligacao = { active: boolean; profile: { email: string } | null };

const ABAS = [
  ['resumo', 'Definições e Cegid'], ['ficha', 'Ficha'], ['documentos', 'Documentos'], ['impostos', 'Impostos'],
  ['pessoal', 'Pessoal'], ['alertas', 'Alertas'], ['mensagens', 'Mensagens e prazos'], ['atividade', 'Atividade'],
] as const;

/* A ficha de uma empresa do portal Empresas, por separadores. */
export default async function Empresa({ params, searchParams }: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ erro?: string; mensagem?: string; mes?: string; aba?: string }>;
}) {
  const [{ id }, pedido] = await Promise.all([params, searchParams]);
  if (!uuid(id)) notFound();
  const { client } = await session();
  const { data: empresa } = await client.from('companies')
    .select('id,name,nif,active,data_corte,data_corte_em,inicio,logotipo_caminho,cegid_versao,company_users(active,profile:profiles(email))')
    .eq('id', id).maybeSingle();
  if (!empresa) notFound();
  const { data: bruto } = await client.rpc('gestao_empresas');
  const estado = (bruto as { empresas?: Record<string, number | string | null>[] } | null)?.empresas?.find((e) => e.id === id);

  const meses = mesesRecentes();
  const dia = Number(new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Lisbon', day: '2-digit' }).format(new Date()));
  const mes = meses.includes(pedido.mes || '') ? pedido.mes! : dia <= 10 ? meses[1] : meses[0];
  const hoje = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Lisbon' }).format(new Date());
  const aba = ABAS.some(([k]) => k === pedido.aba) ? pedido.aba! : 'resumo';
  const contexto: Contexto = { client, id, hoje, mes, meses, empresa };
  const contagem: Record<string, number> = {
    documentos: Number(estado?.por_ver ?? 0), impostos: Number(estado?.impostos_atrasados ?? 0),
    pessoal: Number(estado?.pessoal ?? 0), mensagens: Number(estado?.mensagens ?? 0),
  };
  const ligacoes = (empresa.company_users ?? []) as unknown as Ligacao[];

  return (
    <>
      <Avisos erro={pedido.erro} mensagem={pedido.mensagem} />
      <div className={c.topo}>
        <div>
          <h2>{empresa.name}</h2>
          <p>NIF {empresa.nif} · {ligacoes.filter((l) => l.active).map((l) => l.profile?.email).filter(Boolean).join(', ') || 'sem utilizadores ativos'}</p>
        </div>
        <div className={c.acoes}>
          <Link className="btn btn-secundario btn-sm" href="/empresas">Todas as empresas</Link>
          <a className="btn btn-sm" href={`${PORTAL}/app/${id}`} target="_blank" rel="noopener">Ver no portal</a>
        </div>
      </div>
      <nav className={c.abas} aria-label="Secções da empresa">
        {ABAS.map(([k, nome]) => (
          <Link key={k} className={c.aba} aria-current={k === aba} href={`/empresas/${id}?aba=${k}`}>
            {nome}{contagem[k] ? <span>{contagem[k]}</span> : null}
          </Link>
        ))}
      </nav>
      {aba === 'resumo' && <AbaResumo {...contexto} />}
      {aba === 'ficha' && <AbaFicha {...contexto} />}
      {aba === 'documentos' && <AbaDocumentos {...contexto} />}
      {aba === 'impostos' && <AbaImpostos {...contexto} />}
      {aba === 'pessoal' && <AbaPessoal {...contexto} />}
      {aba === 'alertas' && <AbaAlertas {...contexto} />}
      {aba === 'mensagens' && <AbaMensagens {...contexto} />}
      {aba === 'atividade' && <AbaAtividade {...contexto} />}
    </>
  );
}
