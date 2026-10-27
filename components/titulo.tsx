'use client';

import { usePathname } from 'next/navigation';
import e from './consola.module.css';

const TITULOS: Record<string, string> = {
  '/app': 'Visão geral',
  '/utilizadores': 'Utilizadores e acessos',
  '/empresas': 'Empresas',
  '/descontos': 'Códigos de desconto',
  '/faturacao': 'Faturação',
  '/pagamentos': 'Pagamentos',
  '/configuracao': 'Configurações',
  '/precos': 'Preços e campanhas',
  '/avisos': 'Avisos',
};

export function Titulo() {
  const caminho = usePathname();
  return (
    <div className={e.topoTitulo}>
      <h1>{TITULOS[caminho] ?? 'Gestão'}</h1>
      <span>Gestão de clientes</span>
    </div>
  );
}
