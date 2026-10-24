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
};

export function Titulo() {
  const caminho = usePathname();
  return (
    <div className={e.topoTitulo}>
      <span>Administração</span>
      <h1>{TITULOS[caminho] ?? 'Gestão'}</h1>
    </div>
  );
}
