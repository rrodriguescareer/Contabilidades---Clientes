# Ativar os portais atualizados

## 1. Supabase já instalado

Este projeto já recebeu as migrações 001–004. No mesmo projeto Supabase, abrir SQL Editor → New query e executar o conteúdo **completo** de `supabase/upgrade-005-007.sql`. É uma transação única, preserva utilizadores, documentos originais, faturas e aceitações anteriores. Não executar novamente o instalador inicial.

Numa base ainda vazia, usar `supabase/install.sql`, que inclui todas as migrações. Se 005 já tiver sido aplicada separadamente, aplicar apenas 006 e 007 ainda pendentes; não apagar tabelas para repetir uma instalação.

A versão dos termos e privacidade passa a `2026-10-23.3`. Os clientes existentes confirmam os textos atualizados e completam os novos campos de morada. Não se assume aceitação em nome deles.

## 2. Conta exclusiva do contabilista

A conta `contabilidade.rubenrodrigues@gmail.com` deve existir em Supabase → Authentication → Users e ter email confirmado. A migração reconhece essa conta existente; se for criada ou confirmar o email depois, o trigger atribui a função nesse momento. Não é criada uma password por SQL, nem é guardada uma password do contabilista neste repositório.

A autorização cruza o identificador do utilizador, o email **confirmado** em Auth e `staff_users.active`. Outros membros dessa tabela não recebem acesso à Gestão. O profissional acede à Gestão para gerir utilizadores, empresas, IRS, preços e pagamentos. No Vercel do IRS, definir `NEXT_PUBLIC_GESTAO_URL` para encaminhar a sua conta para a Gestão. Supabase partilhado não elimina a necessidade de iniciar sessão em cada domínio.

## 3. Email de confirmação com a marca RR

Em Supabase → Authentication → Email → Templates (ou Email Templates) → **Confirm sign up**:

- Subject: **RR - IRS - Ativação da Sua Conta**
- Body: conteúdo completo de `supabase/templates/confirm-signup.html`.

Para Recovery e Change email, usar os outros HTML em `supabase/templates/`, com assuntos `RR - IRS - Recuperação de Acesso` e `RR - IRS - Confirmação de Novo Email`.

Em SMTP Settings, ativar **Custom SMTP** com um fornecedor de envio e domínio verificado, por exemplo Resend. Definir nome do remetente **RR - IRS** e um endereço do seu domínio (por exemplo `irs@SEU-DOMINIO.pt`). Os registos SPF/DKIM são os indicados pelo fornecedor. Remetente e nome não são alterados pelo template: sem Custom SMTP continuará a ser usado o serviço padrão do Supabase. Uma conta Gmail normal não pode ser usada como remetente de um domínio diferente; não usar a password de login da plataforma como credencial SMTP.

Manter **Confirm email** e **Secure email change** ativos. Em URL Configuration, configurar Site URL para o IRS e Redirect URLs dos dois `/auth/callback`, incluindo a recuperação de acesso. `NEXT_PUBLIC_SITE_URL` deve corresponder ao domínio de cada aplicação.

Depois de configurar e verificar remetente, assuntos e templates, definir `AUTH_EMAIL_BRANDING_READY=true` no Vercel das duas aplicações e fazer redeploy. Enquanto estiver desligado, o registo e as operações de envio Auth alteradas ficam indisponíveis para evitar o envio do email padrão. Esta variável confirma uma configuração realizada pelo responsável; não altera o SMTP no Supabase.

O código não tem acesso administrativo às configurações Auth remotas; estes passos não foram aplicados automaticamente.

## 4. Convites de familiares

Definir `RESEND_API_KEY` e `MAIL_FROM` com um remetente verificado no Vercel do IRS e da Gestão, se pretende envio automático. Sem estes valores, a plataforma gera uma ligação que o titular pode copiar e partilhar; não afirma que enviou email.

A ligação expira em sete dias. O destinatário cria conta ou entra com o email convidado, confirma o email e aceita o convite. São registados identidade, data e estado. Criar outro convite invalida o anterior pendente. Aceitar confirma a associação ao agregado; não concede acesso aos dados fiscais dos restantes familiares. Os estados são visíveis no cartão do membro e os utilizadores convidados aceites aparecem na Gestão.

## 5. Revolut Merchant

É necessária uma conta Revolut Business com funcionalidade **Merchant** ativa e uma chave privada Merchant; uma API key de conta bancária Business não é equivalente. Esta implementação usa exclusivamente o endereço de produção `https://merchant.revolut.com/api` e checkout alojado pela Revolut. Os dados de cartão não passam pelos portais.

No Vercel do IRS:

| Variável privada | Utilização |
|---|---|
| `SUPABASE_SECRET_KEY` ou `SUPABASE_SERVICE_ROLE_KEY` | Confirmações de pagamento no servidor; nunca `NEXT_PUBLIC_` |
| `REVOLUT_MERCHANT_SECRET_KEY` | Chave privada Merchant de produção |
| `REVOLUT_API_VERSION` | Data de versão suportada e validada para a conta Merchant |
| `REVOLUT_WEBHOOK_SECRET` | Segredo de assinatura do webhook configurado no Merchant |
| `REVOLUT_CHECKOUT_ENABLED` | Manter `false` até concluir a validação; usar `true` para ativar cobrança |

Para consultar/recuperar ordens na Gestão, configurar também as credenciais privadas Merchant e a versão nessa aplicação. A eliminação de autenticação na Gestão precisa apenas da chave administrativa Supabase.

Configurar o webhook Merchant para `https://URL-IRS/api/revolut/webhook`. A assinatura usa o corpo original, timestamp em milissegundos e HMAC SHA-256 `v1.TIMESTAMP.BODY`, com tolerância de cinco minutos. Mesmo depois de verificar a assinatura, o servidor consulta a ordem na Revolut e exige correspondência de ID, referência local, valor em cêntimos e EUR. O retorno ao portal também consulta a ordem; nunca aceita `paid=true` ou valores recebidos do browser como prova de pagamento.

**Limitação de validação externa:** o acesso à documentação oficial da Revolut foi tentado e bloqueado pela rede deste ambiente (HTTP 403 no proxy). O adaptador está implementado, com verificações locais, mas não foi validado contra uma conta Merchant real. Antes de ativar cobranças, confirmar os campos de Create/Retrieve Order, `checkout_url`, `merchant_order_data.reference`, a versão da API, assinatura e eventos do webhook, e o ciclo de uma cobrança/cancelamento na conta. Referências: https://developer.revolut.com/docs/merchant/create-order e https://developer.revolut.com/docs/merchant/retrieve-order.

Se a criação externa falhar ou houver timeout, a tentativa fica por verificar; não se inicia automaticamente outra cobrança. Na Gestão → Pagamentos, procurar a referência local na conta Merchant e recuperar pelo ID da ordem. Uma tentativa sem ID só pode ser libertada manualmente pelo contabilista depois de confirmar ausência de ordem pagável/cobrança, com registo de auditoria. O processamento de reembolsos fica na conta Merchant; não existe botão de reembolso automático nesta versão.

Os clientes gratuitos e os descontos de 100% submetem sem criar uma ordem Revolut. O botão **Pagar e Submeter** envia para revisão pelo contabilista, sem submeter uma declaração à AT. A integração de emissão de faturas Cegid ainda não foi desenvolvida.

## 6. Preços com IVA incluído

| Rubrica | Regra |
|---|---|
| Base | 18,50 € pelo primeiro tipo de rendimento |
| Várias pessoas com trabalho/pensões | +5 € uma única vez |
| Trabalho categoria A + independente categoria B | +15 € |
| Pensões + independente sem categoria A | +5 € |
| Ações e outros títulos (G) | +10 € uma única vez, incluindo quando é o único rendimento |
| Mais-valias de imóveis | +10 € por imóvel distinto, incluindo quando é o único rendimento |
| Só rendas, até 2 imóveis | Sem suplemento: total 18,50 € |
| Rendas com outros tipos, até 2 imóveis | +5 € |
| Rendas, 3–5 imóveis | +10 € |
| Rendas, mais de 5 imóveis | +20 € |

Trabalho e pensões são tratados como um grupo de tipos simples; várias entradas da mesma classe não multiplicam taxas. Despesas/benefícios não acrescentam honorários. Contam-se imóveis distintos, não o número de documentos. Os outros tipos disponíveis são os apresentados no formulário; acrescentar novas classes exige definir o respetivo tarifário. As regras não são cálculos do imposto devido à AT.

Os valores são calculados no banco em cêntimos. O checkout guarda as rubricas e o preço contratado. Se o orçamento mudar desde que foi apresentado, a confirmação é recusada para o cliente voltar a rever o preço. A recolha fica bloqueada durante uma tentativa pendente, incluindo inserções concorrentes.

Na Gestão → Descontos, criar valor fixo ou percentagem, cliente específico, início/fim (UTC), limite global e estado ativo. Todas as restrições se acumulam. Tentativas pendentes reservam utilizações; cancelamentos/falhas confirmados libertam-nas. Em Utilizadores pode definir gratuitidade ou um código obrigatório aplicado automaticamente. A gratuitidade prevalece sobre o código. Uma condição alterada aplica-se ao próximo checkout, sem mudar preços já reservados/pagos. Descontos obrigatórios inválidos/expirados não são ignorados: a cobrança fica bloqueada até correção.

## 7. Documentos e eliminação de contas

Os bytes ficam em Supabase Storage privado, não como base64 em Postgres. A base de dados guarda metadados, contexto fiscal e SHA-256. Ficheiros iguais no mesmo processo usam um único objeto privado, mesmo com várias associações. A deduplicação não é feita entre contas. Os originais PDF/JPEG/PNG até 10 MB são preservados; não se altera um PDF assinado nem se aplica compressão com perda a documentos fiscais.

A autorização e os links temporários continuam a ser verificados por conta. Ficheiros pendentes/rejeitados não são reutilizados automaticamente. Não foi implementado antivírus, OCR, eliminação automática de objetos ou uma política de retenção agendada.

Bloquear um utilizador corta novas leituras com sessões existentes. A eliminação remove a autenticação através da API Admin e anonimiza o perfil da plataforma. Documentos, processos e elementos financeiros sujeitos a conservação permanecem; definir a política de retenção e apagamento legal com base na prestação profissional.
