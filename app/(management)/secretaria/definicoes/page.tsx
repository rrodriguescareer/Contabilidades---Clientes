import { ownerSession } from '@/lib/auth';
import { Avisos } from '@/components/consola';
import { Submeter } from '@/components/forms';
import { CamposCadencia } from '@/components/secretaria/cadencia';
import { EditorModelo } from '@/components/secretaria/editor-modelo';
import { guardarDefinicoes } from '@/lib/secretaria-actions';
import type { Cadencia } from '@/lib/secretaria';
import s from '@/components/secretaria/secretaria.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Definições · Secretária' };

const OPCOES = [
  ['primeiro', 'Só o primeiro email de cada pedido', 'As insistências seguem sozinhas, no calendário. (Recomendado)'],
  ['todos', 'Todos os emails', 'Cada insistência espera também pela sua decisão.'],
  ['nenhum', 'Não pedir aprovação', 'Os emails saem sem passar por «Por aprovar».'],
];

export default async function DefinicoesSecretaria({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  const { client } = await ownerSession();
  const avisos = await searchParams;
  const [{ data: d }, { data: modelos }] = await Promise.all([
    client.from('secretaria_definicoes').select('aprovar,cadencia,dia_limite,resumo_semanal').maybeSingle(),
    client.from('secretaria_modelos').select('tipo,assunto,corpo').is('company_id', null),
  ]);
  const modelo = (t: string) => (modelos ?? []).find((m) => m.tipo === t);
  return (
    <div className={s.pagina}>
      <Avisos erro={avisos.erro} mensagem={avisos.mensagem} />
      <div className={s.intro}><p>Como a Secretária trabalha para todos os clientes. Na ficha de cada um pode definir exceções.</p></div>

      <form action={guardarDefinicoes} className={s.duasIguais}>
        <input type="hidden" name="voltar" value="/secretaria/definicoes" />
        <section className={s.bloco}>
          <div className={s.blocoTitulo}><h3>Aprovar antes de enviar</h3></div>
          <div className={s.opcoes}>
            {OPCOES.map(([v, t, n]) => (
              <label className={s.opcao} key={v}>
                <input type="radio" name="aprovar" value={v} defaultChecked={(d?.aprovar ?? 'primeiro') === v} />
                <div><strong>{t}</strong><span>{n}</span></div>
              </label>
            ))}
          </div>
          <label className="caixa"><input type="checkbox" name="resumo_semanal" defaultChecked={d?.resumo_semanal ?? true} /><span>Resumo semanal por email, à segunda de manhã</span></label>
        </section>
        <section className={s.bloco}>
          <div className={s.blocoTitulo}><h3>Calendário das insistências</h3><p>Hora de Lisboa, com precisão à hora.</p></div>
          <CamposCadencia inicial={(d?.cadencia ?? null) as Cadencia | null} />
          <label className="campo">
            <span>Dia limite habitual (do mês seguinte, de 1 a 28)</span>
            <input name="dia_limite" type="number" min={1} max={28} className="entrada" defaultValue={d?.dia_limite ?? 10} required />
          </label>
          <div className={s.linhaBotoes}><Submeter className="btn btn-sm">Guardar definições</Submeter></div>
        </section>
      </form>

      <div className={s.duasIguais}>
        <EditorModelo titulo="Modelo do primeiro pedido" tipo="pedido" voltar="/secretaria/definicoes" assunto={modelo('pedido')?.assunto ?? ''} corpo={modelo('pedido')?.corpo ?? ''} />
        <EditorModelo titulo="Modelo da insistência" tipo="insistencia" voltar="/secretaria/definicoes" assunto={modelo('insistencia')?.assunto ?? ''} corpo={modelo('insistencia')?.corpo ?? ''} />
      </div>
    </div>
  );
}
