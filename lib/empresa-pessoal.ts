// Cópia de empresas/lib/pessoal.ts.
/* As comunicações de pessoal: o que o contabilista precisa de saber para
   tratar cada caso. Não é um registo de salários: é o pedido, com os dados e
   os documentos, que o gabinete trata e devolve como tratado. */

export type CampoPessoal = {
  nome: string;
  rotulo: string;
  tipo: 'texto' | 'data' | 'numero' | 'escolha' | 'area';
  opcoes?: string[];
  obrigatorio?: boolean;
  ajuda?: string;
};

export const TIPOS_PESSOAL: Record<string, { titulo: string; nota: string; documentos: string; campos: CampoPessoal[] }> = {
  admissao: {
    titulo: 'Admissão',
    nota: 'Comunique com pelo menos 24 horas de antecedência: a admissão tem de ser comunicada à Segurança Social antes do início.',
    documentos: 'Cartão de Cidadão (ou título de residência), comprovativo de IBAN, contrato se já existir.',
    campos: [
      { nome: 'trabalhador', rotulo: 'Nome completo', tipo: 'texto', obrigatorio: true },
      { nome: 'nif', rotulo: 'NIF', tipo: 'texto', obrigatorio: true },
      { nome: 'niss', rotulo: 'NISS (Segurança Social)', tipo: 'texto' },
      { nome: 'nascimento', rotulo: 'Data de nascimento', tipo: 'data', obrigatorio: true },
      { nome: 'morada', rotulo: 'Morada', tipo: 'texto' },
      { nome: 'email', rotulo: 'Email', tipo: 'texto' },
      { nome: 'telefone', rotulo: 'Telefone', tipo: 'texto' },
      { nome: 'inicio', rotulo: 'Data de início', tipo: 'data', obrigatorio: true },
      { nome: 'contrato', rotulo: 'Tipo de contrato', tipo: 'escolha', obrigatorio: true,
        opcoes: ['Sem termo', 'Termo certo', 'Termo incerto', 'Tempo parcial', 'Estágio', 'Outro'] },
      { nome: 'fim_termo', rotulo: 'Fim do termo (se a termo certo)', tipo: 'data' },
      { nome: 'funcao', rotulo: 'Função / categoria', tipo: 'texto', obrigatorio: true },
      { nome: 'vencimento', rotulo: 'Vencimento base mensal (€)', tipo: 'numero', obrigatorio: true },
      { nome: 'subsidio_alimentacao', rotulo: 'Subsídio de alimentação (€/dia e forma)', tipo: 'texto', ajuda: 'Ex.: 10,20 € em cartão' },
      { nome: 'horario', rotulo: 'Horário de trabalho', tipo: 'texto', obrigatorio: true, ajuda: 'Ex.: segunda a sexta, 9h–18h, 40 h/semana' },
      { nome: 'iban', rotulo: 'IBAN do trabalhador', tipo: 'texto' },
      { nome: 'estado_civil', rotulo: 'Estado civil e titulares (para a retenção de IRS)', tipo: 'escolha',
        opcoes: ['Não casado', 'Casado, único titular', 'Casado, dois titulares'] },
      { nome: 'dependentes', rotulo: 'Número de dependentes', tipo: 'numero' },
      { nome: 'observacoes', rotulo: 'Observações', tipo: 'area' },
    ],
  },
  cessacao: {
    titulo: 'Cessação',
    nota: 'O fim do contrato tem de ser comunicado à Segurança Social até ao dia 10 do mês seguinte.',
    documentos: 'Carta de denúncia ou de rescisão, acordo de cessação, se existirem.',
    campos: [
      { nome: 'trabalhador', rotulo: 'Nome do trabalhador', tipo: 'texto', obrigatorio: true },
      { nome: 'nif', rotulo: 'NIF', tipo: 'texto' },
      { nome: 'fim', rotulo: 'Último dia de trabalho', tipo: 'data', obrigatorio: true },
      { nome: 'motivo', rotulo: 'Motivo', tipo: 'escolha', obrigatorio: true,
        opcoes: ['Denúncia pelo trabalhador', 'Fim do termo', 'Acordo de revogação', 'Período experimental', 'Despedimento', 'Reforma', 'Outro'] },
      { nome: 'ferias', rotulo: 'Dias de férias gozados este ano', tipo: 'numero' },
      { nome: 'observacoes', rotulo: 'Observações', tipo: 'area' },
    ],
  },
  ausencia: {
    titulo: 'Ausências',
    nota: 'Férias, baixas, faltas e licenças do mês, para entrarem no processamento.',
    documentos: 'Certificado de incapacidade (baixa), justificações de faltas.',
    campos: [
      { nome: 'trabalhador', rotulo: 'Nome do trabalhador', tipo: 'texto', obrigatorio: true },
      { nome: 'tipo', rotulo: 'Tipo de ausência', tipo: 'escolha', obrigatorio: true,
        opcoes: ['Férias', 'Baixa médica', 'Falta justificada', 'Falta injustificada', 'Licença parental', 'Outra'] },
      { nome: 'de', rotulo: 'De', tipo: 'data', obrigatorio: true },
      { nome: 'ate', rotulo: 'Até', tipo: 'data', obrigatorio: true },
      { nome: 'observacoes', rotulo: 'Observações', tipo: 'area' },
    ],
  },
  alteracao: {
    titulo: 'Alterações',
    nota: 'Mudanças de vencimento, horário, função, morada ou IBAN, prémios e horas extra.',
    documentos: 'Adenda ao contrato ou outro documento que comprove a alteração.',
    campos: [
      { nome: 'trabalhador', rotulo: 'Nome do trabalhador', tipo: 'texto', obrigatorio: true },
      { nome: 'tipo', rotulo: 'O que muda', tipo: 'escolha', obrigatorio: true,
        opcoes: ['Vencimento', 'Horário', 'Função', 'Morada', 'IBAN', 'Prémio ou horas extra', 'Outra'] },
      { nome: 'efeito', rotulo: 'Com efeitos a partir de', tipo: 'data', obrigatorio: true },
      { nome: 'descricao', rotulo: 'Descrição', tipo: 'area', obrigatorio: true },
    ],
  },
};

export const ESTADOS_PESSOAL: Record<string, { texto: string; classe: string }> = {
  novo: { texto: 'Enviado', classe: 'etiqueta etiqueta-acao' },
  em_tratamento: { texto: 'Em tratamento', classe: 'etiqueta etiqueta-atencao' },
  tratado: { texto: 'Tratado', classe: 'etiqueta etiqueta-positivo' },
  devolvido: { texto: 'Devolvido', classe: 'etiqueta etiqueta-critico' },
};

/** Lê os campos do tipo pedido. Só entram os campos conhecidos. */
export function lerPessoal(tipo: string, form: { get(nome: string): FormDataEntryValue | null }) {
  const def = TIPOS_PESSOAL[tipo];
  if (!def) return { erro: 'Escolha o tipo de comunicação.' };
  const dados: Record<string, string> = {};
  for (const c of def.campos) {
    const v = String(form.get(c.nome) ?? '').trim().slice(0, c.tipo === 'area' ? 1500 : 200);
    if (c.obrigatorio && !v) return { erro: `${c.rotulo}: obrigatório.` };
    if (v && c.tipo === 'data' && !/^\d{4}-\d{2}-\d{2}$/.test(v)) return { erro: `${c.rotulo}: data inválida.` };
    if (v && c.tipo === 'numero' && !Number.isFinite(Number(v.replace(',', '.')))) return { erro: `${c.rotulo}: número inválido.` };
    if (v && c.opcoes && !c.opcoes.includes(v)) return { erro: `${c.rotulo}: opção inválida.` };
    if (v) dados[c.nome] = v;
  }
  if (dados.nif && !/^\d{9}$/.test(dados.nif)) return { erro: 'NIF do trabalhador: nove algarismos.' };
  if (dados.niss && !/^\d{11}$/.test(dados.niss)) return { erro: 'NISS do trabalhador: onze algarismos.' };
  const { trabalhador, ...resto } = dados;
  return { trabalhador, dados: resto };
}

export const rotuloPessoal = (tipo: string, campo: string) =>
  TIPOS_PESSOAL[tipo]?.campos.find((c) => c.nome === campo)?.rotulo ?? campo;
