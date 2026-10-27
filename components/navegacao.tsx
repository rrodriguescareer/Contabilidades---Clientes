'use client';

import Link from 'next/link';
import { usePathname, useSearchParams } from 'next/navigation';
import e from './consola.module.css';

/* Um menu só para a ótica do contabilista: o gabinete do IRS e a gestão de
   clientes vivem agora na mesma aplicação, no mesmo endereço. Os processos do
   IRS ficam no topo, porque é por onde o dia começa. */
type Item = { href: string; nome: string; icone: string; contagem?: string };

const GRUPOS: { titulo: string; itens: Item[] }[] = [
  {
    titulo: 'IRS 2026',
    itens: [
      { href: '/irs', nome: 'Processos', icone: 'pasta', contagem: 'a_rever' },
      { href: '/irs?separador=mensagens', nome: 'Mensagens', icone: 'balao', contagem: 'por_responder' },
      { href: '/irs?separador=pagamentos', nome: 'Pagamentos', icone: 'cartao' },
      { href: '/irs?separador=alertas', nome: 'Alertas', icone: 'sino', contagem: 'alertas' },
    ],
  },
  {
    titulo: 'Clientes',
    itens: [
      { href: '/app', nome: 'Visão geral', icone: 'grelha' },
      { href: '/utilizadores', nome: 'Utilizadores e acessos', icone: 'pessoas' },
      { href: '/empresas', nome: 'Empresas', icone: 'predio' },
    ],
  },
  {
    titulo: 'Comercial',
    itens: [
      { href: '/precos', nome: 'Preços e campanhas', icone: 'etiqueta' },
      { href: '/descontos', nome: 'Códigos de desconto', icone: 'percentagem' },
      { href: '/faturacao', nome: 'Faturação', icone: 'recibo' },
    ],
  },
  {
    titulo: 'Sistema',
    itens: [
      { href: '/avisos', nome: 'Avisos', icone: 'megafone' },
      { href: '/irs?separador=integracoes', nome: 'Integração Cegid', icone: 'ficha' },
      { href: '/configuracao', nome: 'Configurações', icone: 'engrenagem' },
    ],
  },
];

export function Navegacao({ contagens = {} }: { contagens?: Record<string, number> }) {
  const caminho = usePathname();
  const procura = useSearchParams();
  const separador = procura.get('separador') || '';

  const atual = (href: string) => {
    const [rota, query] = href.split('?');
    if (rota !== caminho) return false;
    if (rota !== '/irs') return true;
    const pedido = new URLSearchParams(query || '').get('separador') || '';
    return pedido === separador;
  };

  return (
    <nav className={e.navegacao} aria-label="Gestão">
      {GRUPOS.map((g) => (
        <div key={g.titulo} className={e.navBloco}>
          <p className={e.navGrupo}>{g.titulo}</p>
          {g.itens.map((m) => {
            const n = m.contagem ? contagens[m.contagem] : 0;
            return (
              <Link key={m.href} href={m.href} className={e.navLink}
                    aria-current={atual(m.href) ? 'page' : undefined}>
                <Icone nome={m.icone} />
                <span className={e.navNome}>{m.nome}</span>
                {n ? <span className={e.navContagem}>{n}</span> : null}
              </Link>
            );
          })}
        </div>
      ))}
    </nav>
  );
}

export function Icone({ nome }: { nome: string }) {
  const p = {
    width: 18, height: 18, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor',
    strokeWidth: 1.8, strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const, 'aria-hidden': true,
  };
  switch (nome) {
    case 'pasta': return <svg {...p}><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" /></svg>;
    case 'balao': return <svg {...p}><path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z" /></svg>;
    case 'grelha': return <svg {...p}><rect x="3" y="3" width="7" height="7" rx="1.5" /><rect x="14" y="3" width="7" height="7" rx="1.5" /><rect x="3" y="14" width="7" height="7" rx="1.5" /><rect x="14" y="14" width="7" height="7" rx="1.5" /></svg>;
    case 'pessoas': return <svg {...p}><circle cx="9" cy="8" r="3.5" /><path d="M2.5 20a6.5 6.5 0 0 1 13 0" /><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18 14a6 6 0 0 1 3.5 6" /></svg>;
    case 'predio': return <svg {...p}><path d="M4 21V5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v16" /><path d="M16 9h2a2 2 0 0 1 2 2v10M3 21h18M8 7h4M8 11h4M8 15h4" /></svg>;
    case 'etiqueta': return <svg {...p}><path d="M3 12V4a1 1 0 0 1 1-1h8l9 9-9 9z" /><circle cx="7.5" cy="7.5" r="1.5" /></svg>;
    case 'percentagem': return <svg {...p}><path d="M19 5 5 19" /><circle cx="7" cy="7" r="2.5" /><circle cx="17" cy="17" r="2.5" /></svg>;
    case 'recibo': return <svg {...p}><path d="M6 3h12v18l-3-2-3 2-3-2-3 2z" /><path d="M9 8h6M9 12h6" /></svg>;
    case 'cartao': return <svg {...p}><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M3 10h18" /></svg>;
    case 'sino': return <svg {...p}><path d="M6 8a6 6 0 1 1 12 0c0 7 3 8 3 8H3s3-1 3-8" /><path d="M10 20a2 2 0 0 0 4 0" /></svg>;
    case 'ficha': return <svg {...p}><path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z" /><path d="M14 3v6h6M8 13h8M8 17h5" /></svg>;
    case 'megafone': return <svg {...p}><path d="M3 11v2a1 1 0 0 0 1 1h2l5 4V6L6 10H4a1 1 0 0 0-1 1zM15 9a3 3 0 0 1 0 6M18 6a7 7 0 0 1 0 12" /></svg>;
    case 'engrenagem': return <svg {...p}><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" /></svg>;
    default: return <svg {...p}><path d="M4 6h16M4 12h16M4 18h10" /></svg>;
  }
}
