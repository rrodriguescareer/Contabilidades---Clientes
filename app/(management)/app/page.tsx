import Link from 'next/link';
import { session } from '@/lib/auth';
import { Avisos, Secao } from '@/components/consola';
import e from '@/components/consola.module.css';

export const dynamic = 'force-dynamic';

const MODULOS = [
  { href: '/utilizadores', titulo: 'Utilizadores e acessos', nota: 'Clientes, contabilistas, bloqueios e condições de preço.' },
  { href: '/empresas', titulo: 'Empresas', nota: 'Empresas, clientes associados e credenciais Cegid por empresa.' },
  { href: '/descontos', titulo: 'Códigos de desconto', nota: 'Códigos, destinatários, validade e limites de utilização.' },
  { href: '/faturacao', titulo: 'Faturação', nota: 'Documentos emitidos e valores recebidos por serviço.' },
  { href: '/pagamentos', titulo: 'Pagamentos', nota: 'Tentativas por confirmar e reconciliação com a Revolut.' },
  { href: '/configuracao', titulo: 'Configurações', nota: 'Revolut, cifragem e estado das integrações.' },
];

export default async function VisaoGeral({ searchParams }: { searchParams: Promise<{ erro?: string }> }) {
  const { client, context } = await session();
  const parametros = await searchParams;
  const administrador = context.email.toLowerCase() === 'contabilidade.rubenrodrigues@gmail.com';

  const { data, error } = await client.rpc('management_overview');

  const indicadores = administrador
    ? [
        ['Utilizadores', data?.users],
        ['Empresas', data?.companies],
        ['IRS em acompanhamento', data?.open_cases],
        ['Pagamentos por confirmar', data?.pending_payments],
      ]
    : [['IRS em acompanhamento', data?.open_cases]];

  return (
    <>
      <Avisos erro={parametros.erro} />

      {error ? (
        <p className="aviso aviso-atencao">
          Os indicadores precisam da atualização SQL mais recente no Supabase.
        </p>
      ) : (
        <div className="grelha grelha-auto">
          {indicadores.map(([rotulo, valor]) => (
            <div className="cartao cartao-compacto pilha" key={rotulo as string} style={{ gap: '.125rem' }}>
              <strong className="numero" style={{ fontSize: 'var(--t-2xl)', letterSpacing: '-.035em' }}>
                {(valor as number) ?? 0}
              </strong>
              <span className="maiusc tenue">{rotulo as string}</span>
            </div>
          ))}
        </div>
      )}

      {administrador && (
        <Secao titulo="Módulos" nota="Tudo o que administra fica aqui dentro.">
          <div className="grelha grelha-2">
            {MODULOS.map((modulo) => (
              <Link className="cartao cartao-ligado pilha pilha-2" href={modulo.href} key={modulo.href} style={{ textDecoration: 'none' }}>
                <strong>{modulo.titulo}</strong>
                <span className="pequeno suave">{modulo.nota}</span>
              </Link>
            ))}
          </div>
        </Secao>
      )}
    </>
  );
}
