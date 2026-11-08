'use client';

import { usePathname } from 'next/navigation';
import e from './consola.module.css';

const SECRETARIA: Record<string, string> = {
  '/secretaria': 'Painel',
  '/secretaria/clientes': 'Clientes',
  '/secretaria/aprovar': 'Pedidos por aprovar',
  '/secretaria/comunicacoes': 'Comunicações',
  '/secretaria/identificar': 'Por identificar',
  '/secretaria/definicoes': 'Definições',
  '/secretaria/auditoria': 'Auditoria',
};

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
  const secretaria = caminho === '/secretaria' || caminho.startsWith('/secretaria/');
  const titulo = secretaria ? SECRETARIA[caminho] ?? 'Ficha do cliente' : TITULOS[caminho] ?? 'Gestão';
  return (
    <div className={e.topoTitulo}>
      <h1>{titulo}</h1>
      <span>{secretaria ? 'Secretária' : 'Gestão de clientes'}</span>
    </div>
  );
}
