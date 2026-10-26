/* Formatação em português de Portugal, feita uma vez e reutilizada. */

const DATA = new Intl.DateTimeFormat('pt-PT', { day: '2-digit', month: 'short', year: 'numeric' });
const DATA_HORA = new Intl.DateTimeFormat('pt-PT', {
  day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit',
});
const EUROS = new Intl.NumberFormat('pt-PT', { style: 'currency', currency: 'EUR' });

export const data = (valor?: string | null) => (valor ? DATA.format(new Date(valor)) : '—');
export const dataHora = (valor?: string | null) => (valor ? DATA_HORA.format(new Date(valor)) : '—');
export const euros = (centimos: number) => EUROS.format((centimos || 0) / 100);
export const eurosDecimal = (valor: number | string) => EUROS.format(Number(valor) || 0);

export function tamanho(bytes: number) {
  if (!bytes) return '—';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} kB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export const ESTADO_PROCESSO: Record<string, { rotulo: string; classe: string }> = {
  collecting: { rotulo: 'Em recolha', classe: 'etiqueta-acao' },
  submitted_by_client: { rotulo: 'Submetido pelo cliente', classe: 'etiqueta-atencao' },
  accepted: { rotulo: 'Aceite', classe: 'etiqueta-atencao' },
  validation: { rotulo: 'Em validação', classe: 'etiqueta-atencao' },
  approved: { rotulo: 'Aprovado', classe: 'etiqueta-acao' },
  submitting: { rotulo: 'Em submissão', classe: 'etiqueta-acao' },
  filed: { rotulo: 'Submetido na AT', classe: 'etiqueta-positivo' },
  monitoring: { rotulo: 'Em acompanhamento', classe: 'etiqueta-positivo' },
  closed: { rotulo: 'Fechado', classe: 'etiqueta-positivo' },
};

export const ESTADO_DOCUMENTO: Record<string, { rotulo: string; classe: string }> = {
  uploaded: { rotulo: 'Por rever', classe: 'etiqueta-atencao' },
  reviewed: { rotulo: 'Validado', classe: 'etiqueta-positivo' },
  rejected: { rotulo: 'Rejeitado', classe: 'etiqueta-critico' },
  pending: { rotulo: 'Pendente', classe: '' },
};

export const ESTADO_PAGAMENTO: Record<string, { rotulo: string; classe: string }> = {
  creating: { rotulo: 'A iniciar', classe: '' },
  pending: { rotulo: 'A aguardar pagamento', classe: 'etiqueta-atencao' },
  unknown: { rotulo: 'Por confirmar', classe: 'etiqueta-atencao' },
  paid: { rotulo: 'Pago', classe: 'etiqueta-positivo' },
  failed: { rotulo: 'Falhou', classe: 'etiqueta-critico' },
  cancelled: { rotulo: 'Cancelado', classe: 'etiqueta-critico' },
};

/** A recolha só está aberta nestes estados. */
export const editavel = (estado: string) => estado === 'collecting';
