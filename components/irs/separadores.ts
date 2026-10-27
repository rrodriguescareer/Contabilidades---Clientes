/* Os nove separadores de rendimentos, descritos em vez de programados.
 *
 * Eram nove ecrãs quase iguais: mudam os tipos de rendimento, os tipos de
 * documento, e dois ou três interruptores. Escritos à mão seriam nove
 * componentes a divergir uns dos outros à primeira alteração. Aqui são uma
 * tabela, e há um componente só que a lê. */

export type Interruptor = 'irs_jovem' | 'estuda_trabalha';

export type Separador = {
  id: string;
  /** Categoria na base de dados. */
  categoria: string;
  titulo: string;
  /** Uma frase que explica o que entra aqui. */
  ajuda: string;
  /** Os rendimentos penduram-se num imóvel em vez de só num titular. */
  porImovel?: boolean;
  /** Pede datas e valores de compra e venda. */
  maisValias?: boolean;
  /** Pergunta o reinvestimento em habitação própria permanente. */
  reinvestimento?: boolean;
  /** Agrupa por âmbito, para os rendimentos obtidos no estrangeiro. */
  porAmbito?: boolean;
  tipos: string[];
  interruptores: Interruptor[];
  documentos: { tipos: string[]; obrigatorio: boolean; nota: string };
};

const SUPORTE = 'Documentação de Suporte';

const PROVA =
  'Não são obrigatórios, mas é com eles que se valida, prova e confronta o que a AT já tem.';

export const SEPARADORES: Separador[] = [
  {
    id: 'employment',
    categoria: 'employment',
    titulo: 'Trabalho dependente',
    ajuda: 'Salários. Um rendimento por cada membro do agregado que os tenha recebido.',
    tipos: ['Salário', 'Subsídios', 'Outro'],
    interruptores: ['irs_jovem', 'estuda_trabalha'],
    documentos: {
      tipos: [SUPORTE],
      obrigatorio: false,
      nota: `Declaração anual do empregador, recibos de vencimento. ${PROVA}`,
    },
  },
  {
    id: 'pension',
    categoria: 'pension',
    titulo: 'Pensões',
    ajuda: 'Um rendimento por cada membro do agregado com pensões.',
    tipos: ['Pensões de Reforma', 'Pensões de Alimentos', 'Outras Pensões'],
    interruptores: [],
    documentos: { tipos: [SUPORTE], obrigatorio: false, nota: PROVA },
  },
  {
    id: 'independent',
    categoria: 'independent',
    titulo: 'Recibos verdes',
    ajuda: 'Trabalho independente, por titular.',
    tipos: [
      'Atividades do art. 151.º do CIRS — profissões liberais',
      'Outros Tipos de Atividades',
      'Royalties',
      'Outros',
    ],
    interruptores: ['irs_jovem'],
    documentos: { tipos: [SUPORTE], obrigatorio: false, nota: PROVA },
  },
  {
    id: 'capital',
    categoria: 'securities',
    titulo: 'Capitais',
    ajuda: 'Juros e dividendos. Todos os rendimentos têm titular.',
    tipos: ['Juros', 'Dividendos', 'Outros'],
    interruptores: [],
    documentos: { tipos: [SUPORTE], obrigatorio: false, nota: PROVA },
  },
  {
    id: 'property_rent',
    categoria: 'property_rent',
    titulo: 'Rendas',
    ajuda: 'Adicione cada imóvel arrendado e dê-lhe um nome que reconheça.',
    porImovel: true,
    tipos: ['Arrendamento habitacional', 'Arrendamento comercial', 'Outro'],
    interruptores: [],
    documentos: {
      tipos: [SUPORTE, 'Despesas'],
      obrigatorio: false,
      nota: 'As despesas deduzem às rendas recebidas. Cada documento tem de dizer a que imóvel pertence.',
    },
  },
  {
    id: 'property_sale',
    categoria: 'property_sale',
    titulo: 'Mais/menos-valias — imóveis',
    ajuda: 'Um imóvel por cada venda, com as datas e os valores de compra e de venda.',
    porImovel: true,
    maisValias: true,
    reinvestimento: true,
    tipos: ['Habitação própria permanente', 'Outro imóvel'],
    interruptores: [],
    documentos: {
      tipos: ['Escritura de Compra', 'Escritura de Venda', 'Despesas', 'Reinvestimento HPP', 'Outros'],
      obrigatorio: true,
      nota: 'Obrigatórios. Cada documento tem de dizer a que imóvel pertence.',
    },
  },
  {
    id: 'securities_sale',
    categoria: 'securities',
    titulo: 'Mais/menos-valias — ações e outros',
    ajuda: 'Com as mesmas datas e valores dos imóveis: compra, venda e despesas.',
    maisValias: true,
    tipos: ['Ações', 'Obrigações', 'Unidades de Participação', 'Outros'],
    interruptores: [],
    documentos: {
      tipos: [SUPORTE],
      obrigatorio: true,
      nota: 'Obrigatórios. Envie os documentos anuais da corretora, que já trazem os códigos certos.',
    },
  },
  {
    id: 'foreign_income',
    categoria: 'foreign_income',
    titulo: 'Rendimentos estrangeiros',
    ajuda: 'Obtidos fora de Portugal, agrupados pelo tipo a que correspondem.',
    porAmbito: true,
    tipos: [],
    interruptores: [],
    documentos: {
      tipos: [
        'Trabalho dependente e pensões',
        'Capitais',
        'Rendas',
        'Mais-valias',
        'Outros',
      ],
      obrigatorio: true,
      nota: 'Obrigatórios, por tipo de rendimento.',
    },
  },
];

/** Os grupos do separador dos rendimentos estrangeiros. */
export const AMBITOS: { id: string; titulo: string }[] = [
  { id: 'employment', titulo: 'Rendimentos do trabalho dependente e pensões' },
  { id: 'independent', titulo: 'Rendimentos de trabalho independente' },
  { id: 'capital', titulo: 'Rendimentos de capitais' },
  { id: 'rent', titulo: 'Rendas' },
  { id: 'property_sale', titulo: 'Mais-valias de imóveis' },
  { id: 'securities', titulo: 'Mais-valias de ações e outros' },
  { id: 'other', titulo: 'Outros rendimentos' },
];

export const DEDUCOES = {
  id: 'deduction',
  titulo: 'Deduções e benefícios',
  ajuda: 'Deduções à coleta e benefícios fiscais.',
  documentos: {
    tipos: ['PPR', 'Despesas com ascendentes', 'Arrendamento', 'Outros'],
    nota: 'O comprovativo do PPR é obrigatório quando declara um.',
  },
};

export const separadorDe = (id: string) => SEPARADORES.find((s) => s.id === id);

/* As mais-valias de ações e o separador dos capitais partilham a mesma
   categoria na base de dados. Distinguem-se por terem, ou não, data de venda.
   As duas óticas usam isto, para mostrarem cada linha no mesmo separador. */
export const pertence = (
  r: { categoria: string; venda_em: string | null },
  s: Pick<Separador, 'id' | 'categoria'>,
) => {
  if (s.id === 'capital') return r.categoria === 'securities' && !r.venda_em;
  if (s.id === 'securities_sale') return r.categoria === 'securities' && !!r.venda_em;
  return r.categoria === s.categoria;
};

/** O IRS Jovem só se pergunta a quem tem idade para ele. */
export function temIdadeParaIrsJovem(nascimento: string | null | undefined, ano = 2026) {
  if (!nascimento) return false;
  const anos = ano - new Date(nascimento).getFullYear();
  return anos >= 0 && anos <= 35;
}

/** Os tipos de documento aceites num separador. Vazio = não restringe. */
export function tiposDocumentaisDe(categoria: string | null | undefined): string[] {
  if (!categoria) return [];
  if (categoria === DEDUCOES.id) return DEDUCOES.documentos.tipos;
  const tipos = SEPARADORES.filter((s) => s.categoria === categoria).flatMap(
    (s) => s.documentos.tipos,
  );
  // As ações e os capitais partilham categoria: aceita-se o que qualquer um
  // dos dois separadores permite, mais o saco de "outra documentação".
  return [...new Set([...tipos, 'Outra Documentação'])];
}
