/* Os rótulos vivem no lib/fluxo, que é o fluxo todo num sítio só. Isto é só a
   porta de entrada para a consola, mais os rótulos que são dela. */
export { ROTULOS as ESTADOS, MEUS } from '@/lib/fluxo';

export const PAGAMENTOS: Record<string, string> = {
  paid: 'Pago',
  pending: 'A aguardar',
  unknown: 'Por confirmar',
  failed: 'Falhou',
  cancelled: 'Cancelado',
};

/* Os alertas chegavam à fila com o nome técnico. Quem olha para a consola
   precisa de saber o que fazer, não como a coluna se chama. */
export const ALERTAS: Record<string, { rotulo: string; urgente?: boolean }> = {
  nif_bloqueado: {
    rotulo: 'Conflito de NIF — tem de ser resolvido por si',
    urgente: true,
  },
  nif_conta: { rotulo: 'NIF já usado noutra conta' },
  nif_agregado: { rotulo: 'NIF já consta noutro agregado' },
  nif_recusado: { rotulo: 'NIF recusado pelo Cegid', urgente: true },
  two_factor: { rotulo: 'Dois fatores ativo — é preciso contactar' },
};
