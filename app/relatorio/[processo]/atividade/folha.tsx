import { ROTULOS } from '@/lib/fluxo';
import { dataHora, type DetalheStripe, type Relatorio } from '@/lib/relatorio-atividade';
import { Imprimir } from './imprimir';
import r from './atividade.module.css';

const euros = (c: number | null | undefined) =>
  c == null ? '—' : (c / 100).toLocaleString('pt-PT', { style: 'currency', currency: 'EUR' });
const dia = (iso: string | null | undefined) =>
  iso ? new Intl.DateTimeFormat('pt-PT', { timeZone: 'Europe/Lisbon' }).format(new Date(iso)) : '—';

const ESTADO_PAGAMENTO: Record<string, string> = {
  paid: 'Pago', pending: 'A aguardar', unknown: 'Por confirmar', failed: 'Falhado', cancelled: 'Cancelado', creating: 'Iniciado',
};

export function Folha({ processo, dados, stripe }: { processo: string; dados: Relatorio; stripe: DetalheStripe[] }) {

  const c = dados.cliente || {};
  const p = dados.processo as Record<string, string | number | null>;
  const emitido = dataHora(new Date().toISOString());
  const referencia = `RA-${p.ano}-${processo.slice(0, 8).toUpperCase()}`;
  const conta = (tipo: string) => dados.eventos.filter((e) => e.evento === tipo).length;

  return (
    <main className={r.folha}>
      <Imprimir csv={`/relatorio/${processo}/csv`} />

      <header className={r.cabecalho}>
        <img src="/rr.svg" alt="RR." width={259} height={142} className={r.logo} />
        <div>
          <h1>Relatório de atividade e prova de prestação de serviço</h1>
          <p className={r.en}>Activity log and proof of service delivery</p>
        </div>
        <table className={r.ref}>
          <tbody>
            <tr><th>Referência</th><td>{referencia}</td></tr>
            <tr><th>Emitido em</th><td>{emitido}</td></tr>
            <tr><th>Fuso horário</th><td>Europe/Lisbon</td></tr>
          </tbody>
        </table>
      </header>

      <section>
        <h2>1. Prestador do serviço <span className={r.en}>Service provider</span></h2>
        <table className={r.ficha}>
          <tbody>
            <tr><th>Nome</th><td>Rúben Miguel da Silva Duarte Meirinho Rodrigues</td></tr>
            <tr><th>Qualidade</th><td>Contabilista Certificado — cédula profissional n.º 145854</td></tr>
            <tr><th>Domicílio profissional</th><td>Rua Augusto Simões 845, 4470-147 Maia, Portugal</td></tr>
            <tr><th>Contacto</th><td>contabilidade.rubenrodrigues@gmail.com</td></tr>
            <tr><th>Plataforma</th><td>irs.rr-contabilidade.com</td></tr>
          </tbody>
        </table>
      </section>

      <section>
        <h2>2. Cliente <span className={r.en}>Customer</span></h2>
        <table className={r.ficha}>
          <tbody>
            <tr><th>Nome</th><td>{c.nome || '—'}</td></tr>
            <tr><th>NIF</th><td>{c.nif || '—'}</td></tr>
            <tr><th>Email</th><td>{c.email || '—'}</td></tr>
            <tr><th>Telemóvel</th><td>{c.telefone || '—'}</td></tr>
            <tr><th>Morada</th><td>{c.morada || '—'}</td></tr>
            <tr><th>Data de nascimento</th><td>{dia(c.nascimento)}</td></tr>
            <tr><th>Conta criada em</th><td>{dataHora(c.conta_criada)}</td></tr>
            <tr><th>Email confirmado em</th><td>{dataHora(c.email_confirmado)}</td></tr>
            <tr><th>Último acesso</th><td>{dataHora(c.ultimo_acesso)}</td></tr>
          </tbody>
        </table>
      </section>

      <section>
        <h2>3. Serviço e pagamento <span className={r.en}>Service and payment</span></h2>
        <table className={r.ficha}>
          <tbody>
            <tr><th>Serviço</th><td>Recolha, revisão, preparação e submissão da declaração de IRS (campanha {p.ano}), com acompanhamento até ao fecho</td></tr>
            <tr><th>Processo</th><td>{processo}</td></tr>
            <tr><th>Estado atual</th><td>{ROTULOS[String(p.estado)] || String(p.estado)}</td></tr>
            <tr><th>Processo aberto em</th><td>{dataHora(p.aberto as string)}</td></tr>
            <tr><th>Submetido pelo cliente em</th><td>{dataHora(p.submetido as string | null)}</td></tr>
            {p.valor_final != null && (
              <tr><th>Valor apurado</th><td>{euros(p.valor_final as number)} {p.sentido === 'refund' ? 'a reembolsar' : 'a pagar'}</td></tr>
            )}
          </tbody>
        </table>

        <table className={r.grelha}>
          <thead>
            <tr><th>Tentativa</th><th>Estado</th><th>Valor</th><th>Desconto</th><th>Iniciada</th><th>Paga</th><th>Sessão Stripe</th></tr>
          </thead>
          <tbody>
            {dados.pagamentos.length === 0 ? (
              <tr><td colSpan={7}>Sem pagamentos.</td></tr>
            ) : dados.pagamentos.map((k) => (
              <tr key={k.id}>
                <td className={r.mono}>{k.id.slice(0, 8)}</td>
                <td>{ESTADO_PAGAMENTO[k.estado] || k.estado}</td>
                <td className={r.num}>{euros(k.total)}</td>
                <td className={r.num}>{k.desconto ? euros(k.desconto) : '—'}</td>
                <td className={r.nowrap}>{dataHora(k.criado)}</td>
                <td className={r.nowrap}>{dataHora(k.pago_em)}</td>
                <td className={r.mono}>{k.sessao || '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>

        {stripe.map((s) => s && (
          <table className={r.ficha} key={s.sessao}>
            <caption>Registo do Stripe para a sessão {s.sessao}</caption>
            <tbody>
              <tr><th>Payment Intent</th><td className={r.mono}>{s.intencao || '—'}</td></tr>
              <tr><th>Cobrança (charge)</th><td className={r.mono}>{s.cobranca || '—'}</td></tr>
              <tr><th>Data da cobrança</th><td>{dataHora(s.criado)}</td></tr>
              <tr><th>Método</th><td>{s.metodo || '—'}{s.cartao ? ` · ${s.cartao}` : ''}{s.pais ? ` · emitido em ${s.pais}` : ''}</td></tr>
              {s.tresDS && <tr><th>3-D Secure</th><td>{s.tresDS}</td></tr>}
              {s.cvc && <tr><th>Verificação CVC</th><td>{s.cvc}</td></tr>}
              <tr><th>Resposta da rede</th><td>{s.rede || '—'}{s.risco ? ` · risco ${s.risco}` : ''}</td></tr>
              <tr><th>Pagador (no Stripe)</th><td>{[s.nome, s.email].filter(Boolean).join(' · ') || '—'}</td></tr>
            </tbody>
          </table>
        ))}
      </section>

      <section>
        <h2>4. Resumo <span className={r.en}>Summary</span></h2>
        <table className={r.grelha}>
          <thead>
            <tr><th>Entradas na conta</th><th>Rendimentos declarados</th><th>Documentos enviados</th><th>Mensagens</th><th>Passos do processo</th><th>Total de registos</th></tr>
          </thead>
          <tbody>
            <tr>
              <td className={r.num}>{conta('Entrada na conta')}</td>
              <td className={r.num}>{conta('Rendimento declarado')}</td>
              <td className={r.num}>{conta('Documento enviado')}</td>
              <td className={r.num}>{dados.eventos.filter((e) => e.evento.startsWith('Mensagem')).length}</td>
              <td className={r.num}>{dados.eventos.filter((e) => e.origem === 'Contabilista' && !e.evento.startsWith('Mensagem')).length}</td>
              <td className={r.num}>{dados.eventos.length}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section>
        <h2>5. Registo cronológico <span className={r.en}>Chronological log</span></h2>
        <table className={`${r.grelha} ${r.registo}`}>
          <thead>
            <tr>
              <th>N.º</th>
              <th>Data e hora<span className={r.en}>Date &amp; time</span></th>
              <th>Origem<span className={r.en}>Source</span></th>
              <th>Evento<span className={r.en}>Event</span></th>
              <th>Detalhe<span className={r.en}>Details</span></th>
            </tr>
          </thead>
          <tbody>
            {dados.eventos.map((e, i) => (
              <tr key={i}>
                <td className={r.num}>{i + 1}</td>
                <td className={r.nowrap}>{dataHora(e.em)}</td>
                <td>{e.origem}</td>
                <td>{e.evento}</td>
                <td className={r.detalhe}>{e.detalhe || ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className={r.nota}>
          Os registos foram gerados automaticamente pela plataforma no momento de cada ação e conservados na sua base de
          dados. Datas e horas na hora legal de Lisboa. Os endereços IP e browsers constam das entradas registadas a partir de
          28/10/2026.
        </p>
      </section>

      <section className={r.declaracao}>
        <h2>6. Declaração <span className={r.en}>Statement</span></h2>
        <p>
          Declaro, na qualidade de Contabilista Certificado, que o presente relatório reproduz fielmente os registos da
          plataforma irs.rr-contabilidade.com relativos ao cliente e ao processo acima identificados, e que o serviço
          contratado foi disponibilizado e prestado nos termos descritos, tendo o cliente acedido à plataforma, aceitado os
          Termos e Condições e utilizado o serviço nas datas indicadas.
        </p>

        <div className={r.assinatura}>
          <div>
            <span className={r.linha} />
            <p>Local e data</p>
            <p className={r.preenchido}>Maia, ____ / ____ / ________</p>
          </div>
          <div>
            <span className={r.linha} />
            <p>Assinatura</p>
            <p className={r.preenchido}>Rúben Miguel da Silva Duarte Meirinho Rodrigues</p>
            <p>Contabilista Certificado · Cédula n.º 145854</p>
          </div>
        </div>
      </section>
    </main>
  );
}
