# Contabilidades — Gestão de Clientes

Aplicação privada Next.js + TypeScript para gerir clientes e processos, ligada ao mesmo Supabase que o [Portal IRS](https://github.com/rrodriguescareer/Contabilidades---IRS). O acesso exige um utilizador autenticado e autorização de profissional no banco.

## Publicação no Vercel

- Importar este repositório, branch `main`, Framework **Next.js**, diretório raiz, Node.js **24**.
- Build: `npm run build`. O `next start` usa o modo de produção; o Vercel gere o arranque.
- Configurar as variáveis antes de fazer Redeploy:

| Nome | Valor |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://rllajahyovpzndbbyvcd.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Publishable key do Supabase |
| `NEXT_PUBLIC_SITE_URL` | URL pública desta aplicação Gestão, com `https://` |
| `NEXT_PUBLIC_IRS_URL` | URL pública do Portal IRS |

Em alternativa à publishable, pode usar `NEXT_PUBLIC_SUPABASE_ANON_KEY`. O código também aceita `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` e `SUPABASE_ANON_KEY`, usados por algumas integrações. As duas aplicações usam a mesma URL e chave pública, mantendo `NEXT_PUBLIC_SITE_URL` diferente. Não é necessária uma integração automática Vercel/Supabase para cada projeto.

Nunca utilizar `service_role`, secret key ou a password da base de dados no frontend. O código recusa chaves privilegiadas. Sem configuração, o acesso fica indisponível e não são apresentados dados alternativos.

## Migrações — projeto Supabase partilhado

Aplicar **uma vez e pela ordem indicada**, através do SQL Editor ou CLI de migrações:

1. `supabase/migrations/202610230001_core.sql`
2. `supabase/migrations/202610230002_legal_acceptances.sql`
3. `supabase/migrations/202610230003_production_legal_version.sql`

Se as anteriores já foram aplicadas, executar apenas as pendentes. Não repetir as migrações iniciais nem executar outra cópia no IRS. A versão legal atual é `2026-10-23.2`; o histórico anterior é preservado e não se assume aceitação em nome do cliente.

A primeira migração cria tabelas, RLS, funções e o bucket privado `irs-documents`. As seguintes criam o histórico imutável de aceitação e exigem a versão atual antes de autorizar leituras fiscais do cliente. Não foram aplicadas ao projeto remoto por este desenvolvimento: não estão disponíveis neste ambiente credenciais de administração do Supabase.

## Primeiro profissional

Criar o utilizador em Supabase → Authentication → Users, confirmando o email. Depois executar no SQL Editor, substituindo o email:

```sql
insert into public.staff_users(user_id)
select id from auth.users where lower(email) = lower('SEU_EMAIL_PROFISSIONAL')
on conflict(user_id) do update set active=true;
```

Confirmar que foi afetada uma linha e entrar pela rota `/entrar`. O registo público de clientes não concede privilégios profissionais.

## URLs de autenticação

Em Supabase → Authentication → URL Configuration:

- Site URL: endereço estável do IRS.
- Redirect URLs: `https://URL-IRS/auth/callback` e `https://URL-GESTAO/auth/callback`.
- Cada Vercel precisa do seu `NEXT_PUBLIC_SITE_URL` correto.

Configurar e verificar o envio de emails pelo serviço Auth/SMTP. Partilhar Supabase não partilha automaticamente a sessão entre domínios.

## Funcionalidades

Aprovação de registos, abertura de conta/processo IRS e titular numa transação, concessão/revogação de módulos, consulta do agregado e rendimentos, documentos privados, mensagens, progresso e alertas de 2FA. Faturas e pagamentos existentes são consultados.

Convites: nesta versão existem pedidos registados, sem envio/aceitação automática nem permissões amplas para familiares. Cofre fiscal, pagamentos, OCR, anexos diretamente no chat, notificações, Realtime e a plataforma Empresas ainda não estão implementados. O portal não emite faturas fiscais nem submete declarações à AT. A senha das Finanças não é recolhida enquanto não existir cofre.

## Operação e verificação

O endereço inicial abre a área autenticada. Os antigos caminhos `/teste` e `/demonstracao` apenas redirecionam para `/entrar`; não há contas fictícias, cenários ou substituição de dados reais. Os ficheiros ficam privados; formatos PDF/JPEG/PNG até 10 MB, assinatura verificada no servidor e links assinados de 60 segundos. Ainda não existe análise antivírus automática.

As alterações de acesso bloqueiam novas leituras e novos links assinados; links já emitidos podem manter-se válidos até expirarem. O titular tem acesso à conta aprovada; a autorização individual de familiares será desenvolvida antes de ativar esses acessos.

Verificar antes de receber dados reais: migrações, conta profissional, registo/confirmação/recuperação, aceitação legal, aprovação IRS, carregamento/download, leitura entre duas contas distintas, revogação, mensagens e progresso. Os dados pessoais ainda não têm snapshots históricos completos por exercício. Configurar retenção e backups de acordo com o serviço.

## Desenvolvimento e qualidade

```sh
npm ci
npm run build
npm run typecheck
npm run test:config
npm run test:db
```

Para desenvolvimento local, preencher `.env.local` a partir de `.env.example` e executar `npm run dev -- --port 3001`. Os testes automáticos usam exclusivamente dados locais isolados e não criam utilizadores ou documentos na plataforma publicada. A validação local não substitui a verificação do projeto Supabase e do deploy Vercel reais.
