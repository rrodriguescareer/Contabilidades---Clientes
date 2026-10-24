import ConnectionDiagnostic from '@/components/connection-diagnostic';
import { ownerSession } from '@/lib/auth';
import { Avisos, Secao } from '@/components/consola';
import { adminConfigured, adminClient } from '@/lib/admin-client';
import { savePaymentSettings } from '@/lib/integration-actions';
import { Submeter } from '@/components/forms';
import e from '@/components/consola.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Configurações' };

function Estado({ pronto, sim, nao }: { pronto: boolean; sim: string; nao: string }) {
  return <span className={`etiqueta ${pronto ? 'etiqueta-positivo' : 'etiqueta-atencao'}`}>{pronto ? sim : nao}</span>;
}

export default async function Configuracao({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  const { client } = await ownerSession();
  const parametros = await searchParams;

  const { data: definicoes } = await client.from('payment_settings').select('enabled,api_version').eq('id', true).single();

  const { data: segredos } = adminConfigured()
    ? await adminClient().from('integration_secrets').select('scope').in('scope', ['revolut:merchant', 'revolut:webhook'])
    : { data: [] };

  const temMerchant = Boolean(segredos?.some((s) => s.scope === 'revolut:merchant'));
  const temWebhook = Boolean(segredos?.some((s) => s.scope === 'revolut:webhook'));
  const cifragemPronta = /^[a-f0-9]{64}$/i.test(process.env.INTEGRATION_ENCRYPTION_KEY || '');
  const podeGuardar = adminConfigured() && cifragemPronta;

  return (
    <>
      <Avisos erro={parametros.erro} mensagem={parametros.mensagem} />

      <div className={e.fichaCaixas}>
        <Secao titulo="Revolut Merchant" nota="Configuração partilhada com o portal do IRS. Campos vazios mantêm as chaves já guardadas.">
          <div className="cartao pilha pilha-4">
            <div className="linha">
              <Estado pronto={temMerchant} sim="Chave Merchant guardada" nao="Chave Merchant por configurar" />
              <Estado pronto={temWebhook} sim="Webhook guardado" nao="Webhook por configurar" />
              <Estado pronto={Boolean(definicoes?.enabled)} sim="Pagamentos ativos" nao="Pagamentos desativados" />
            </div>

            <form action={savePaymentSettings} className="pilha pilha-4">
              <label className="campo">
                <span>Versão da API Merchant</span>
                <input
                  name="version"
                  className="entrada"
                  defaultValue={definicoes?.api_version || ''}
                  placeholder="AAAA-MM-DD"
                  pattern="[0-9]{4}-[0-9]{2}-[0-9]{2}"
                  required
                />
              </label>
              <label className="campo">
                <span>Nova chave secreta Merchant</span>
                <input name="merchant_key" type="password" className="entrada" autoComplete="new-password" maxLength={4096} />
              </label>
              <label className="campo">
                <span>Novo segredo de assinatura do webhook</span>
                <input name="webhook_secret" type="password" className="entrada" autoComplete="new-password" maxLength={4096} />
              </label>
              <label className="caixa">
                <input name="enabled" type="checkbox" defaultChecked={definicoes?.enabled || false} />
                <span className="pequeno">Ativar pagamentos online.</span>
              </label>
              <label className="caixa">
                <input name="validated" type="checkbox" />
                <span className="pequeno">Validei o checkout e o webhook na minha conta Revolut Merchant.</span>
              </label>

              {podeGuardar ? (
                <Submeter className="btn" aDecorrer="A guardar…">
                  Guardar configuração
                </Submeter>
              ) : (
                <p className="aviso aviso-atencao">
                  Falta a configuração privada do servidor indicada ao lado.
                </p>
              )}
            </form>
          </div>
        </Secao>

        <Secao titulo="Ligação entre aplicações">
          <div className="cartao pilha pilha-4">
            <ConnectionDiagnostic />
            <div className="linha">
              <Estado pronto={adminConfigured()} sim="Administração configurada" nao="Administração por configurar" />
              <Estado pronto={cifragemPronta} sim="Cifragem configurada" nao="Cifragem por configurar" />
            </div>
            <p className="pequeno suave">
              Nas duas aplicações Vercel, configure a mesma <code>INTEGRATION_ENCRYPTION_KEY</code> com 64
              caracteres hexadecimais, além de <code>SUPABASE_SECRET_KEY</code>. A chave de cifragem é gerada uma
              única vez e nunca mais substituída depois de haver credenciais guardadas.
            </p>
            <p className="pequeno suave">
              Na Revolut, aponte as notificações para <code>https://[domínio-do-IRS]/api/revolut/webhook</code>.
              Nunca ponha chaves secretas em variáveis com prefixo <code>NEXT_PUBLIC</code>.
            </p>
          </div>
        </Secao>
      </div>

      <Secao titulo="Email e registo de clientes">
        <div className="cartao pilha pilha-3">
          <p className="suave">
            O cliente regista-se diretamente no portal do IRS e preenche os dados depois de confirmar o email. Os
            acessos de contabilista e de empresas são atribuídos por si em Utilizadores e Empresas.
          </p>
          <p className="suave">
            Configure o remetente RR no SMTP do Supabase e o template de confirmação com o assunto{' '}
            <strong>RR - IRS - Ativação da Sua Conta</strong>. Depois de validar os emails, defina{' '}
            <code>AUTH_EMAIL_BRANDING_READY=true</code> nas duas aplicações Vercel.
          </p>
        </div>
      </Secao>

      <Secao titulo="Campanha IRS 2026">
        <div className="cartao">
          <p className="suave">
            Existe uma única campanha visível. Os dados pessoais e o agregado mantêm-se de ano para ano. A
            preparação da campanha seguinte e a conservação dos elementos fiscais serão configuradas antes de
            qualquer limpeza — não há eliminação automática.
          </p>
        </div>
      </Secao>
    </>
  );
}
