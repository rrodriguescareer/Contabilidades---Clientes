import ConnectionDiagnostic from '@/components/connection-diagnostic';
import { ownerSession } from '@/lib/auth';
import { Avisos, Secao } from '@/components/consola';
import { adminConfigured } from '@/lib/admin-client';
import e from '@/components/consola.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Configurações' };

function Estado({ pronto, sim, nao }: { pronto: boolean; sim: string; nao: string }) {
  return <span className={`etiqueta ${pronto ? 'etiqueta-positivo' : 'etiqueta-atencao'}`}>{pronto ? sim : nao}</span>;
}

export default async function Configuracao({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  await ownerSession();
  const parametros = await searchParams;

  const cifragemPronta = /^[a-f0-9]{64}$/i.test(process.env.INTEGRATION_ENCRYPTION_KEY || '');

  return (
    <>
      <Avisos erro={parametros.erro} mensagem={parametros.mensagem} />

      <div className={e.fichaCaixas}>
        <Secao titulo="Pagamentos" nota="Processados pela Stripe, dentro do portal do IRS.">
          <div className="cartao pilha pilha-3">
            <p className="suave">
              As chaves da Stripe (secreta, publicável e o segredo do webhook) vivem nas variáveis de ambiente da
              aplicação do IRS na Vercel, nunca na base de dados. Os métodos de pagamento — cartão, MB WAY,
              Multibanco, Apple Pay, Google Pay, PayPal, Revolut Pay e Klarna — ligam-se e desligam-se no painel da
              Stripe; o checkout mostra os que lá estiverem ativos.
            </p>
            <p className="pequeno suave">
              O webhook aponta para <code>https://irs.rr-contabilidade.com/api/stripe</code>. Antes de abrir ao
              público, troque as chaves de teste pelas de produção e crie o webhook de produção.
            </p>
            <div>
              <a className="btn btn-secundario" href="https://dashboard.stripe.com" target="_blank" rel="noopener">
                Abrir o painel da Stripe
              </a>
            </div>
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
