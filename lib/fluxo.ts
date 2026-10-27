/* O fluxo do processo, num sítio só.
   Antes havia três listas de estados — uma no percurso do cliente, uma na
   consola e uma no lib/data.ts — e nenhuma dizia a que nível do processo cada
   estado pertencia. São quatro fases: a recolha é do cliente, a análise é
   minha, a entrega é na AT e a conclusão é a resposta dela. */

export type Fase = 'recolha' | 'analise' | 'entrega' | 'conclusao';
/** De quem se espera o próximo movimento. É isto que decide o tom do ecrã. */
export type Espera = 'cliente' | 'gabinete' | 'at' | 'ninguem';

export type Estado = {
  id: string;
  fase: Fase;
  /** O que o cliente lê. */
  titulo: string;
  /** A frase que explica o momento ao cliente. */
  nota: string;
  /** O nome curto que eu vejo na consola e nas listas. */
  curto: string;
  espera: Espera;
  /** Fora da linha principal: devolvido e divergência são desvios. */
  desvio?: boolean;
};

export const FASES: { id: Fase; titulo: string; nota: string }[] = [
  { id: 'recolha', titulo: 'Recolha', nota: 'Reunir os dados e os documentos do agregado.' },
  { id: 'analise', titulo: 'Análise', nota: 'Conferência e aprovação no gabinete.' },
  { id: 'entrega', titulo: 'Entrega', nota: 'Submissão da declaração na Autoridade Tributária.' },
  { id: 'conclusao', titulo: 'Conclusão', nota: 'Liquidação, reembolso ou pagamento.' },
];

export const ESTADOS: Estado[] = [
  {
    id: 'collecting', fase: 'recolha', espera: 'cliente',
    titulo: 'Em recolha', curto: 'Em recolha',
    nota: 'Está a reunir os dados e os documentos. Quando estiver tudo, submete o processo.',
  },
  {
    id: 'returned', fase: 'recolha', espera: 'cliente', desvio: true,
    titulo: 'Devolvido para completar', curto: 'Devolvido',
    nota: 'Faltam elementos. Complete o que está em falta e submeta outra vez.',
  },
  {
    id: 'submitted_by_client', fase: 'analise', espera: 'gabinete',
    titulo: 'Submetido', curto: 'Submetido',
    nota: 'Recebi o processo. Está na minha fila.',
  },
  {
    id: 'accepted', fase: 'analise', espera: 'gabinete',
    titulo: 'Aceite', curto: 'Aceite',
    nota: 'Confirmei a receção e abri o processo.',
  },
  {
    id: 'validation', fase: 'analise', espera: 'gabinete',
    titulo: 'Em validação', curto: 'Em validação',
    nota: 'Estou a conferir os rendimentos e os documentos.',
  },
  {
    id: 'approved', fase: 'analise', espera: 'gabinete',
    titulo: 'Aprovado', curto: 'Aprovado',
    nota: 'Está tudo conferido. Segue para submissão.',
  },
  {
    id: 'submitting', fase: 'entrega', espera: 'gabinete',
    titulo: 'Em submissão', curto: 'Em submissão',
    nota: 'A declaração está a ser entregue no Portal das Finanças.',
  },
  {
    id: 'filed', fase: 'entrega', espera: 'at',
    titulo: 'Submetido na AT', curto: 'Entregue',
    nota: 'Entregue. Fica registado o valor apurado.',
  },
  {
    id: 'monitoring', fase: 'conclusao', espera: 'at',
    titulo: 'Em acompanhamento', curto: 'Acompanhamento',
    nota: 'À espera da validação da Autoridade Tributária.',
  },
  {
    id: 'divergence', fase: 'conclusao', espera: 'gabinete', desvio: true,
    titulo: 'Em divergência', curto: 'Divergência',
    nota: 'A Autoridade Tributária levantou uma questão. Estou a tratar dela.',
  },
  {
    id: 'assessed', fase: 'conclusao', espera: 'at',
    titulo: 'Liquidação emitida', curto: 'Liquidada',
    nota: 'A liquidação saiu. O valor apurado está confirmado.',
  },
  {
    id: 'closed', fase: 'conclusao', espera: 'ninguem',
    titulo: 'Fechado', curto: 'Fechado',
    nota: 'Processo concluído.',
  },
];

const porId = new Map(ESTADOS.map((e) => [e.id, e]));
export const estadoDe = (id: string | null | undefined): Estado | null =>
  (id && porId.get(id)) || null;

/** Os títulos com que o avancar_processo grava os eventos. É por eles que o
    percurso reconhece um desvio no registo. */
export const TITULOS_DE_EVENTO: Record<string, string> = {
  submitted_by_client: 'Processo submetido',
  accepted: 'Processo aceite',
  validation: 'Em validação',
  approved: 'Aprovado',
  submitting: 'Em processo de submissão',
  filed: 'Submetido na Autoridade Tributária',
  monitoring: 'Em acompanhamento',
  divergence: 'Em divergência',
  assessed: 'Liquidação emitida',
  closed: 'Processo fechado',
  returned: 'Devolvido para completar',
  collecting: 'Recolha reaberta',
};

/** Um evento é um desvio quando o seu título é o de um estado de desvio. */
const DESVIOS = new Set(
  ESTADOS.filter((e) => e.desvio).map((e) => TITULOS_DE_EVENTO[e.id]),
);
export const eDesvio = (titulo: string) => DESVIOS.has(titulo);

/** Os rótulos curtos, para quem só precisa do nome. */
export const ROTULOS: Record<string, string> = Object.fromEntries(
  ESTADOS.map((e) => [e.id, e.curto]),
);

/** A linha principal, sem os desvios: é a espinha do percurso. */
export const LINHA = ESTADOS.filter((e) => !e.desvio);

/** Quantos passos da linha principal já ficaram para trás. */
export function posicao(estado: string | null | undefined) {
  const e = estadoDe(estado);
  if (!e) return { indice: 0, fase: 'recolha' as Fase, total: LINHA.length };
  // Um desvio conta como estando no primeiro passo da sua fase.
  const alvo = e.desvio ? LINHA.find((x) => x.fase === e.fase) : e;
  return {
    indice: LINHA.findIndex((x) => x.id === alvo?.id),
    fase: e.fase,
    total: LINHA.length,
  };
}

/** A frase do topo: quem está a trabalhar agora. */
export const QUEM: Record<Espera, string> = {
  cliente: 'À espera de si',
  gabinete: 'Comigo',
  at: 'Na Autoridade Tributária',
  ninguem: 'Concluído',
};

/* ------------------------------------------------- o que eu posso fazer */

export type Passo = { destino: string; rotulo: string; tom: 'avancar' | 'desvio' | 'recuo' };

/** Espelha o transicoes_do_estado da base de dados. Quem decide é ela; isto é
    só a forma de o pedir, com as palavras certas e o tom certo no botão. */
export const PASSOS: Record<string, Passo[]> = {
  collecting: [
    { destino: 'submitted_by_client', rotulo: 'Marcar como submetido', tom: 'avancar' },
  ],
  returned: [
    { destino: 'accepted', rotulo: 'Aceitar assim mesmo', tom: 'avancar' },
    { destino: 'submitted_by_client', rotulo: 'Marcar como submetido', tom: 'desvio' },
  ],
  submitted_by_client: [
    { destino: 'accepted', rotulo: 'Aceitar processo', tom: 'avancar' },
    { destino: 'returned', rotulo: 'Devolver ao cliente', tom: 'desvio' },
  ],
  accepted: [
    { destino: 'validation', rotulo: 'Começar validação', tom: 'avancar' },
    { destino: 'returned', rotulo: 'Devolver ao cliente', tom: 'desvio' },
  ],
  validation: [
    { destino: 'approved', rotulo: 'Aprovar', tom: 'avancar' },
    { destino: 'returned', rotulo: 'Devolver ao cliente', tom: 'desvio' },
  ],
  approved: [
    { destino: 'submitting', rotulo: 'Iniciar submissão', tom: 'avancar' },
    { destino: 'validation', rotulo: 'Voltar à validação', tom: 'recuo' },
  ],
  submitting: [
    { destino: 'filed', rotulo: 'Registar entrega', tom: 'avancar' },
    { destino: 'approved', rotulo: 'Voltar a aprovado', tom: 'recuo' },
  ],
  filed: [
    { destino: 'monitoring', rotulo: 'Pôr em acompanhamento', tom: 'avancar' },
  ],
  monitoring: [
    { destino: 'assessed', rotulo: 'Registar liquidação', tom: 'avancar' },
    { destino: 'divergence', rotulo: 'Abrir divergência', tom: 'desvio' },
    { destino: 'closed', rotulo: 'Fechar processo', tom: 'avancar' },
    { destino: 'filed', rotulo: 'Voltar a entregue', tom: 'recuo' },
  ],
  divergence: [
    { destino: 'assessed', rotulo: 'Divergência resolvida', tom: 'avancar' },
    { destino: 'monitoring', rotulo: 'Voltar a acompanhamento', tom: 'recuo' },
  ],
  assessed: [
    { destino: 'closed', rotulo: 'Fechar processo', tom: 'avancar' },
    { destino: 'divergence', rotulo: 'Abrir divergência', tom: 'desvio' },
  ],
  closed: [
    { destino: 'assessed', rotulo: 'Reabrir na liquidação', tom: 'recuo' },
    { destino: 'monitoring', rotulo: 'Reabrir acompanhamento', tom: 'recuo' },
  ],
};

/** Os estados que esperam por mim. A fila usa isto para o filtro "meus". */
export const MEUS = ESTADOS.filter((e) => e.espera === 'gabinete').map((e) => e.id);

export type Prontidao = {
  chave: string;
  rotulo: string;
  estado: 'ok' | 'falta' | 'atencao';
  detalhe: string;
  de: 'cliente' | 'gabinete';
  bloqueia: boolean;
};

/** Os dois estados em que o cliente pode mexer no processo. É o mesmo que o
    can_edit_case da base de dados permite: recolha e devolvido. */
export const emRecolha = (estado: string | null | undefined) =>
  estado === 'collecting' || estado === 'returned';
