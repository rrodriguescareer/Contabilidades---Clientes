import Link from 'next/link';
import { session } from '@/lib/auth';
import { Avisos, Secao } from '@/components/consola';
import { Icone } from '@/components/navegacao';
import e from '@/components/consola.module.css';

export const dynamic = 'force-dynamic';

const MODULOS = [
  { href: '/utilizadores', titulo: 'Utilizadores e acessos', nota: 'Clientes, acessos ao IRS e às empresas, bloqueios e condições de preço.', icone: 'pessoas' },
  { href: '/empresas', titulo: 'Empresas', nota: 'Empresas, clientes associados e credenciais Cegid por empresa.', icone: 'predio' },
  { href: '/precos', titulo: 'Preços e campanhas', nota: 'Política de preços do IRS e campanhas com datas.', icone: 'etiqueta' },
  { href: '/descontos', titulo: 'Códigos de desconto', nota: 'Códigos, destinatários, validade e limites de utilização.', icone: 'percentagem' },
  { href: '/faturacao', titulo: 'Faturação', nota: 'Documentos emitidos e valores recebidos por serviço.', icone: 'recibo' },
  { href: '/irs?separador=pagamentos', titulo: 'Pagamentos do IRS', nota: 'Pagamentos Stripe, recebidos e por liquidar.', icone: 'cartao' },
  { href: '/avisos', titulo: 'Avisos', nota: 'Mensagens que aparecem no website e na plataforma do IRS.', icone: 'megafone' },
  { href: '/configuracao', titulo: 'Configurações', nota: 'Integrações, cifragem e estado do sistema.', icone: 'engrenagem' },
];

export default async function VisaoGeral({ searchParams }: { searchParams: Promise<{ erro?: string }> }) {
  const { client, context } = await session();
  const parametros = await searchParams;
  const administrador = context.email.toLowerCase() === 'contabilidade.rubenrodrigues@gmail.com';

  const { data, error } = await client.rpc('management_overview');

  const indicadores: [string, unknown, string | null][] = [
    ['IRS em acompanhamento', data?.open_cases, '/irs'],
    ...(administrador
      ? ([
          ['Utilizadores', data?.users, '/utilizadores'],
          ['Empresas', data?.companies, '/empresas'],
          ['Pagamentos por confirmar', data?.pending_payments, '/irs?separador=pagamentos'],
        ] as [string, unknown, string | null][])
      : []),
  ];

  return (
    <>
      <Avisos erro={parametros.erro} />

      {error ? (
        <p className="aviso aviso-atencao">Os indicadores precisam da atualização SQL mais recente no Supabase.</p>
      ) : (
        <div className={e.indicadores}>
          {indicadores.map(([rotulo, valor, destino]) => {
            const conteudo = (<><strong>{(valor as number) ?? 0}</strong><span>{rotulo}</span></>);
            return destino
              ? destino.startsWith('http')
                ? <a key={rotulo} className={e.indicador} href={destino}>{conteudo}</a>
                : <Link key={rotulo} className={e.indicador} href={destino}>{conteudo}</Link>
              : <div key={rotulo} className={e.indicador}>{conteudo}</div>;
          })}
        </div>
      )}

      {administrador && (
        <Secao titulo="Módulos" nota="Tudo o que administra fica aqui dentro.">
          <div className={e.modulos}>
            {MODULOS.map((m) => (
              <Link className={e.modulo} href={m.href} key={m.href}>
                <Icone nome={m.icone} />
                <strong>{m.titulo}</strong>
                <span>{m.nota}</span>
              </Link>
            ))}
          </div>
        </Secao>
      )}
    </>
  );
}
