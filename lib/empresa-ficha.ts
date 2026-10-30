// Cópia de empresas/lib/ficha.ts: as mesmas regras nos dois lados.
/* A ficha da empresa: os campos, como se validam e como se mostram. Funções
   puras, partilhadas pelo formulário e pelo servidor (a base volta a validar). */

export const REGIMES_IVA: Record<string, string> = {
  mensal: 'Normal mensal',
  trimestral: 'Normal trimestral',
  isento_53: 'Isento (art. 53.º do CIVA)',
  outro: 'Outro',
};

export const FORMAS_JURIDICAS = [
  'Sociedade por quotas', 'Sociedade unipessoal por quotas', 'Sociedade anónima', 'Empresário em nome individual',
  'Trabalhador independente', 'Associação', 'Cooperativa', 'Outra',
];

export type Campo = {
  nome: string;
  rotulo: string;
  tipo: 'texto' | 'area' | 'escolha' | 'numero' | 'sim' | 'email' | 'telefone';
  ajuda?: string;
  opcoes?: Record<string, string> | string[];
  max?: number;
  obrigatorio?: boolean;
  grupo: 'Identificação' | 'Fiscalidade' | 'Morada' | 'Segurança Social e banco' | 'Contactos';
};

export const CAMPOS: Campo[] = [
  { nome: 'nome', rotulo: 'Denominação', tipo: 'texto', max: 200, obrigatorio: true, grupo: 'Identificação' },
  { nome: 'nif', rotulo: 'NIF', tipo: 'texto', max: 9, obrigatorio: true, grupo: 'Identificação' },
  { nome: 'forma_juridica', rotulo: 'Forma jurídica', tipo: 'escolha', opcoes: FORMAS_JURIDICAS, grupo: 'Identificação' },
  { nome: 'capital_social', rotulo: 'Capital social (€)', tipo: 'numero', grupo: 'Identificação' },
  { nome: 'representantes', rotulo: 'Gerentes, administradores e representantes legais', tipo: 'area', max: 1000, ajuda: 'Um por linha: nome, NIF e cargo.', grupo: 'Identificação' },
  { nome: 'cae', rotulo: 'CAE', tipo: 'texto', max: 70, ajuda: 'O principal primeiro; vários separados por vírgula.', grupo: 'Fiscalidade' },
  { nome: 'regime_iva', rotulo: 'Regime de IVA', tipo: 'escolha', opcoes: REGIMES_IVA, grupo: 'Fiscalidade' },
  { nome: 'regime_iva_outro', rotulo: 'Se outro, qual', tipo: 'texto', max: 200, grupo: 'Fiscalidade' },
  { nome: 'tem_trabalhadores', rotulo: 'Tem trabalhadores por conta de outrem', tipo: 'sim', grupo: 'Fiscalidade' },
  { nome: 'morada', rotulo: 'Morada da sede', tipo: 'texto', max: 300, grupo: 'Morada' },
  { nome: 'codigo_postal', rotulo: 'Código postal', tipo: 'texto', max: 8, ajuda: '0000-000', grupo: 'Morada' },
  { nome: 'localidade', rotulo: 'Localidade', tipo: 'texto', max: 100, grupo: 'Morada' },
  { nome: 'niss', rotulo: 'NISS da empresa', tipo: 'texto', max: 11, ajuda: 'Número de identificação na Segurança Social, 11 algarismos.', grupo: 'Segurança Social e banco' },
  { nome: 'iban', rotulo: 'IBAN', tipo: 'texto', max: 40, grupo: 'Segurança Social e banco' },
  { nome: 'email', rotulo: 'Email da empresa', tipo: 'email', max: 254, grupo: 'Contactos' },
  { nome: 'telefone', rotulo: 'Telefone da empresa', tipo: 'telefone', max: 30, grupo: 'Contactos' },
  { nome: 'contacto_nome', rotulo: 'Pessoa de contacto', tipo: 'texto', max: 200, grupo: 'Contactos' },
  { nome: 'contacto_email', rotulo: 'Email da pessoa de contacto', tipo: 'email', max: 254, grupo: 'Contactos' },
  { nome: 'contacto_telefone', rotulo: 'Telefone da pessoa de contacto', tipo: 'telefone', max: 30, grupo: 'Contactos' },
];

export const rotuloDoCampo = (nome: string) => CAMPOS.find((c) => c.nome === nome)?.rotulo ?? nome;

export function nifValido(nif: string) {
  if (!/^[1-9]\d{8}$/.test(nif)) return false;
  const soma = [...nif.slice(0, 8)].reduce((t, d, i) => t + Number(d) * (9 - i), 0);
  const controlo = 11 - (soma % 11);
  return (controlo >= 10 ? 0 : controlo) === Number(nif[8]);
}

export function ibanValido(iban: string) {
  if (!/^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$/.test(iban)) return false;
  const rearranjado = iban.slice(4) + iban.slice(0, 4);
  let resto = 0;
  for (const c of rearranjado) {
    const v = /\d/.test(c) ? c : String(c.charCodeAt(0) - 55);
    for (const d of v) resto = (resto * 10 + Number(d)) % 97;
  }
  return resto === 1;
}

/** Lê e valida a ficha de um formulário. Devolve os valores normalizados ou o
    primeiro erro, escrito para quem o vai corrigir. */
export function lerFicha(form: { get(nome: string): FormDataEntryValue | null }) {
  const dados: Record<string, string | boolean> = {};
  for (const c of CAMPOS) {
    if (c.tipo === 'sim') { dados[c.nome] = form.get(c.nome) === 'on' || form.get(c.nome) === 'true'; continue; }
    const v = String(form.get(c.nome) ?? '').trim();
    if (c.max && v.length > c.max) return { erro: `${c.rotulo}: demasiado longo.` };
    if (c.obrigatorio && !v) return { erro: `${c.rotulo}: obrigatório.` };
    dados[c.nome] = v;
  }
  const t = (k: string) => String(dados[k] || '');
  if (!nifValido(t('nif'))) return { erro: 'NIF inválido: confirme os nove algarismos.' };
  if (t('cae') && !/^\d{5}(\s*[,;]\s*\d{5}){0,9}$/.test(t('cae'))) return { erro: 'CAE: cinco algarismos, vários separados por vírgula.' };
  if (t('regime_iva') && !REGIMES_IVA[t('regime_iva')]) return { erro: 'Regime de IVA inválido.' };
  if (t('codigo_postal') && !/^\d{4}-\d{3}$/.test(t('codigo_postal'))) return { erro: 'Código postal no formato 0000-000.' };
  if (t('niss') && !/^\d{11}$/.test(t('niss'))) return { erro: 'NISS: onze algarismos.' };
  if (t('iban')) {
    dados.iban = t('iban').replace(/\s+/g, '').toUpperCase();
    if (!ibanValido(t('iban'))) return { erro: 'IBAN inválido: confirme os algarismos.' };
  }
  if (t('capital_social')) {
    const n = Number(t('capital_social').replace(/\s/g, '').replace(',', '.'));
    if (!Number.isFinite(n) || n < 0) return { erro: 'Capital social inválido.' };
    dados.capital_social = n.toFixed(2);
  }
  for (const k of ['email', 'contacto_email']) if (t(k) && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(t(k))) return { erro: `${rotuloDoCampo(k)}: email inválido.` };
  for (const k of ['telefone', 'contacto_telefone']) if (t(k) && (t(k).length < 6 || !/^[+\d\s()-]+$/.test(t(k)))) return { erro: `${rotuloDoCampo(k)}: número inválido.` };
  return { dados };
}

/** Como um valor guardado se lê no histórico. */
export function valorLegivel(campo: string, valor: string | null) {
  if (valor == null || valor === '') return '—';
  if (campo === 'regime_iva') return REGIMES_IVA[valor] ?? valor;
  if (campo === 'tem_trabalhadores') return valor === 'true' ? 'Sim' : 'Não';
  return valor;
}
