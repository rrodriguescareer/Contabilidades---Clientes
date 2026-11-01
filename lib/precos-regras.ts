/* As regras de preço, do lado da aplicação: os tipos, os nomes legíveis e a
   frase que descreve cada regra. A base de dados valida e calcula
   (problema_nas_regras, preco_por_regras); isto só ajuda a ler e a editar. */

export type Condicao =
  | { tipo: 'categoria'; modo: 'alguma' | 'todas' | 'nenhuma'; categorias: string[] }
  | { tipo: 'contagem'; medida: string; min?: number | null; max?: number | null };

export type Regra = {
  id: string;
  ordem?: number;
  rotulo: string;
  valor_cents: number;
  ativa?: boolean;
  condicoes: Condicao[];
  por_unidade?: { medida: string; acima_de: number } | null;
  anula?: string[];
};

export const CATEGORIAS: Record<string, string> = {
  employment: 'Trabalho Dependente',
  pension: 'Pensões',
  independent: 'Independente',
  securities: 'Capitais e Mais-Valias (Ações)',
  property_rent: 'Rendas',
  property_sale: 'Mais-Valias (Imóveis)',
  foreign_income: 'Rendimentos Estrangeiros',
  other: 'Outros',
};

export const MEDIDAS: Record<string, string> = {
  tipos_rendimento: 'Tipos de rendimento',
  rendimentos: 'Rendimentos declarados',
  pessoas_trabalho: 'Pessoas com trabalho ou pensões',
  imoveis_renda: 'Imóveis arrendados',
  imoveis_venda: 'Imóveis vendidos',
  membros: 'Pessoas no agregado',
  dependentes: 'Dependentes',
};

export const MODOS: Record<string, string> = {
  alguma: 'tem algum de',
  todas: 'tem todos',
  nenhuma: 'não tem nenhum de',
};

const euros = (c: number) => new Intl.NumberFormat('pt-PT', { style: 'currency', currency: 'EUR' }).format((c || 0) / 100);

/** «Quando…»: as condições de uma regra numa frase. */
export function quando(r: Regra) {
  const partes = (r.condicoes || []).map((c) => {
    if (c.tipo === 'categoria') return `${MODOS[c.modo] ?? c.modo} ${c.categorias.map((x) => CATEGORIAS[x] ?? x).join(', ')}`;
    const m = (MEDIDAS[c.medida] ?? c.medida).toLowerCase();
    if (c.min != null && c.max != null) return c.min === c.max ? `${m}: ${c.min}` : `${m}: de ${c.min} a ${c.max}`;
    if (c.min != null) return `${m}: ${c.min} ou mais`;
    if (c.max != null) return `${m}: até ${c.max}`;
    return m;
  });
  return partes.length ? partes.join(' · ') : 'sempre';
}

/** O valor, com a cobrança por unidade quando há. */
export function quanto(r: Regra) {
  if (!r.por_unidade) return euros(r.valor_cents);
  const m = (MEDIDAS[r.por_unidade.medida] ?? r.por_unidade.medida).toLowerCase();
  return `${euros(r.valor_cents)} × ${m}${r.por_unidade.acima_de ? ` acima de ${r.por_unidade.acima_de}` : ''}`;
}
