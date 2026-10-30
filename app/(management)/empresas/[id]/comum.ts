import type { SupabaseClient } from '@supabase/supabase-js';

/* O que as abas da ficha de uma empresa partilham. */

export type Contexto = {
  client: SupabaseClient;
  id: string;
  hoje: string;
  mes: string;
  meses: string[];
  empresa: {
    id: string; name: string; nif: string; data_corte: string | null; data_corte_em: string | null;
    inicio: string | null; logotipo_caminho: string | null; cegid_versao: number;
  };
};

export const PORTAL = (process.env.NEXT_PUBLIC_EMPRESAS_URL || 'https://portal.rr-contabilidade.com').replace(/\/$/, '');
export const MESES = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];

const lisboa = (o: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat('pt-PT', { timeZone: 'Europe/Lisbon', ...o });
export const dataHora = (iso: string | null) => (iso ? lisboa({ day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(iso)) : '—');
export const data = (iso: string | null) => (iso ? iso.slice(0, 10).split('-').reverse().join('/') : '—');
export const nomeMes = (mes: string) => { const [a, m] = mes.split('-').map(Number); return `${MESES[m - 1]} de ${a}`; };
export const tamanho = (b: number) => (b < 1024 * 1024 ? `${Math.max(1, Math.round(b / 1024))} KB` : `${(b / 1024 / 1024).toFixed(1).replace('.', ',')} MB`);
export const euros = (v: number) => new Intl.NumberFormat('pt-PT', { style: 'currency', currency: 'EUR', useGrouping: 'always' } as Intl.NumberFormatOptions).format(v);

export function mesesRecentes(quantos = 13) {
  const hoje = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Lisbon' }).format(new Date());
  const [a, m] = hoje.split('-').map(Number);
  return Array.from({ length: quantos }, (_, i) => {
    const d = new Date(Date.UTC(a, m - 1 - i, 1));
    return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
  });
}

export const TIPOS_ATIVIDADE: Record<string, string> = {
  data_corte: 'Data de corte', documento: 'Documento', documento_atrasado: 'Documento fora do prazo', documento_eliminado: 'Documento apagado',
  documento_devolvido: 'Devolvido', mes_completo: 'Mês entregue', mes_conferido: 'Mês conferido', balancete: 'Balancete consultado',
  balancete_pdf: 'Balancete PDF', balancete_xlsx: 'Balancete Excel', extrato: 'Extrato', extrato_pdf: 'Extrato PDF', extrato_xlsx: 'Extrato Excel',
  saldos: 'Saldos', clientes: 'Clientes', fornecedores: 'Fornecedores', bancos: 'Bancos', comprovativo: 'Comprovativo de entrega',
  ficha: 'Ficha', logotipo: 'Logótipo', definicoes: 'Definições', pessoal: 'Pessoal', recibos: 'Recibos', imposto: 'Impostos', descarga: 'Descarga',
};
