'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import e from './consola.module.css';

type Modulo = { href: string; nome: string; numero: string };

const CLIENTES: Modulo[] = [
  { href: '/app', nome: 'Visão geral', numero: '01' },
  { href: '/utilizadores', nome: 'Utilizadores e acessos', numero: '02' },
  { href: '/empresas', nome: 'Empresas', numero: '03' },
];

const COMERCIAL: Modulo[] = [
  { href: '/descontos', nome: 'Códigos de desconto', numero: '04' },
  { href: '/faturacao', nome: 'Faturação', numero: '05' },
  { href: '/pagamentos', nome: 'Pagamentos', numero: '06' },
];

const SISTEMA: Modulo[] = [{ href: '/configuracao', nome: 'Configurações', numero: '07' }];

export function Navegacao({ irs }: { irs: string | null }) {
  const caminho = usePathname();

  const grupo = (titulo: string, modulos: Modulo[]) => (
    <>
      <p className={e.navGrupo}>{titulo}</p>
      {modulos.map((modulo) => (
        <Link
          key={modulo.href}
          href={modulo.href}
          className={e.navLink}
          aria-current={caminho === modulo.href ? 'page' : undefined}
        >
          <span className={e.navNumero}>{modulo.numero}</span>
          {modulo.nome}
        </Link>
      ))}
    </>
  );

  return (
    <nav className={e.navegacao} aria-label="Gestão">
      {grupo('Clientes', CLIENTES)}
      {grupo('Comercial', COMERCIAL)}
      {grupo('Sistema', SISTEMA)}

      {/* Os processos de IRS vivem na plataforma do IRS, no espaço do
          contabilista. Aqui fica só a porta de entrada. */}
      {irs && (
        <>
          <p className={e.navGrupo}>Noutra plataforma</p>
          <a className={e.navLink} href={`${irs}/gabinete`} target="_blank" rel="noopener noreferrer">
            <span className={e.navNumero}>↗</span>
            Gabinete IRS 2026
          </a>
        </>
      )}
    </nav>
  );
}
