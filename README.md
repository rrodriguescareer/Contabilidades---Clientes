# Contabilidades — Gestão de Clientes

Aplicação Next.js 16 + TypeScript para o profissional. Repositório separado do Portal IRS, com design próprio, ligado ao mesmo projeto Supabase.

## Estado desta primeira versão

Implementado: login e recuperação, proteção da gestão por papel de profissional no banco, aprovação de registos (cria conta + titular + processo IRS numa transação), concessão/revogação de módulos, consulta do agregado e rendimentos, upload/download privado, mensagens, progresso e alertas de 2FA. O cliente inicia o registo na aplicação IRS. Não são utilizados dados demonstrativos no produto.

Ainda não implementado: envio/aceitação de convites de familiares (há registo de pedidos), credenciais fiscais em cofre, formulários fiscais estruturados completos por classe/ano, OCR, anexos diretamente no chat, notificações, Realtime, emissão fiscal, integração de pagamentos e plataforma Empresas. Faturas e pagamentos existentes no banco são apenas consultados. A sessão entre domínios não é automaticamente partilhada; a identidade Auth é a mesma.

## 1. Variáveis no Vercel

Importar este repositório como **Next.js**, diretório raiz, Node.js 24. Não é necessário escolher um template. Em Settings → Environment Variables, configurar nos ambientes pretendidos e depois fazer Redeploy:

| Nome | Valor |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://rllajahyovpzndbbyvcd.supabase.co` (sem `/rest/v1/`) |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Publishable key do projeto, `sb_publishable_...` |
| `NEXT_PUBLIC_SITE_URL` | URL pública desta aplicação, com `https://` |
| `NEXT_PUBLIC_IRS_URL` | URL pública da aplicação IRS |

Se o projeto apresentar apenas chaves antigas, usar `NEXT_PUBLIC_SUPABASE_ANON_KEY` em vez de `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`. Nunca colocar `service_role`, secret key, JWT secret ou password da base de dados nestas variáveis públicas.

Sem URL/chave, a aplicação apresenta configuração em falta e não tenta autenticar nem guardar dados. As variáveis do Vercel não são automaticamente copiadas para outros projetos ou para o ambiente local.

## 2. Preparar o Supabase — uma vez, neste repositório

Projeto partilhado: **Contabilidades Ruben Rodrigues**. Começar num ambiente de desenvolvimento, com dados de teste.

1. No Supabase, abrir SQL Editor → New query.
2. Colar e executar integralmente [`supabase/migrations/202610230001_core.sql`](supabase/migrations/202610230001_core.sql).
3. A migração cria tabelas, funções, índices, RLS e o bucket privado `irs-documents`. É uma migração inicial, não um script a repetir. Os nomes são novos e uma colisão faz a transação falhar, em vez de substituir dados existentes. Não executar novamente se já tiver sido aplicada.
4. Não executar outra cópia no repositório IRS. Ambas as aplicações usam estas mesmas tabelas.

Esta migração foi verificada localmente em PostgreSQL/PGlite com fixtures dos esquemas Auth e Storage; não foi aplicada por este desenvolvimento ao projeto remoto.

## 3. Criar o primeiro profissional

1. Supabase → Authentication → Users → Add user. Criar o seu utilizador profissional e confirmar o email pelos mecanismos do Supabase. Não usar passwords de clientes.
2. No SQL Editor, substituir o email abaixo pelo **seu email profissional exato** e executar:

```sql
insert into public.staff_users(user_id)
select id from auth.users where lower(email) = lower('SEU_EMAIL_PROFISSIONAL')
on conflict(user_id) do update set active=true;
```

3. Confirmar que foi inserida/atualizada uma linha. Se não houver linha, o utilizador com esse email ainda não existe.
4. Entrar na Gestão com esse email e a password definida. Os clientes comuns não conseguem atribuir a si próprios o papel profissional. Não há registo público de profissionais.

## 4. Autenticação e emails

No Supabase → Authentication → URL Configuration, adicionar ambos os callbacks às Redirect URLs:

- `https://URL-IRS/auth/callback`
- `https://URL-GESTAO/auth/callback`
- as versões locais, quando se usa desenvolvimento (`http://localhost:3000/auth/callback` e `http://localhost:3001/auth/callback`).

Definir Site URL para o endereço estável do IRS. Cada aplicação usa `NEXT_PUBLIC_SITE_URL` para pedir callbacks exatos. Confirmar configurações de confirmação de email e o serviço SMTP para emails reais. A existência de uma chave publicável não garante entrega de email.

## 5. Percurso de validação real

- No IRS, criar um cliente de teste e confirmar o email.
- Na Gestão, abrir Clientes e acessos e aprovar o registo, escolhendo o ano dos rendimentos.
- No IRS, entrar e verificar o processo criado, adicionar agregado/rendimentos e enviar um PDF de teste sem informação pessoal.
- Confirmar que a Gestão vê o documento, mensagem e alerta 2FA; publicar uma atualização e verificar no IRS.
- Enviar o processo para revisão: o cliente deixa de carregar novos elementos até a Gestão reabrir como «Elementos em falta».
- Criar um segundo cliente e confirmar que não consegue ver os dados do primeiro. Revogar o acesso e confirmar bloqueio das novas leituras.

A gestão recebe estado «Submetido» apenas por registo do profissional; a aplicação não submete declarações à AT. A senha do Portal das Finanças **não é recolhida nem guardada** enquanto não houver cofre implementado.

## Desenvolvimento e testes

```sh
npm ci
cp .env.example .env.local
# Preencher apenas as variáveis públicas de desenvolvimento.
npm run dev -- --port 3001
npm run build
npm run typecheck
npm run test:db
```

`test:db` usa uma instância PostgreSQL em memória e testa 10 cenários: isolamento entre contas, impossibilidade de autopromoção, alerta 2FA único, relações dentro do mesmo processo, autor de mensagens, autorização de documentos/Storage, bloqueio para revisão, pedidos de convite sem acesso implícito, faturação e revogação. Não testa emails/Auth/Storage HTTP do Supabase real.

Documentos: PDF/JPEG/PNG até 10 MB, assinatura do formato verificada no servidor, bucket privado, links assinados de 60 segundos e download como anexo. Ainda não há análise antivírus automática. A expiração curta limita a validade de um link já emitido; revogar acesso impede novas emissões, mas não revoga retroativamente um URL assinado ainda válido.

## Limites do modelo inicial

Só titulares de conta ativos com acesso IRS podem ler o agregado; familiares convidados não recebem permissões amplas enquanto o escopo individual não estiver implementado. As permissões são impostas no banco, não apenas na navegação.

Os dados das pessoas desta primeira versão não têm snapshots históricos completos por ano; a UI não permite alterar o nome/NIF/nascimento de pessoas existentes. A evolução para múltiplos exercícios e versões será feita por migrações adicionais, preservando o histórico.

Não existe integração de faturação: o portal não cria documentos fiscais. O bucket não é público e os segredos de serviços externos não pertencem às tabelas ou ao navegador. Rever política de privacidade/retensão e configurar backups antes de introduzir dados reais de clientes.

## Explorar sem configurar Supabase

A rota `/demonstracao` funciona sem variáveis de ambiente ou base de dados. Sem configuração, o endereço inicial abre automaticamente essa demonstração. A entrada real continua em `/entrar`, com ligação de volta ao exemplo. Depois de configurar o Supabase, o endereço inicial passa para a área autenticada.

A demonstração identifica claramente dados fictícios em memória: agregado, rendimentos, imóveis, documentos simulados, mensagens e progresso. Na Gestão também permite simular concessões de módulos e acompanhar alertas. Não tem uploads reais, emails, passwords ou persistência; recarregar repõe os exemplos. As duas aplicações não sincronizam estes dados entre si. A demonstração não abre ou contorna os dados protegidos em `/app`.

### Integração automática Vercel / Supabase

Uma integração automática num projeto Vercel não é necessária no segundo. O segundo projeto pode usar os mesmos valores públicos de URL e chave do primeiro, mantendo o seu próprio `NEXT_PUBLIC_SITE_URL`. O código também aceita os aliases de servidor `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` e `SUPABASE_ANON_KEY`, frequentemente disponibilizados por integrações. Nunca usa a variável genérica `SUPABASE_KEY`, porque o seu tipo seria ambíguo. Chaves `sb_secret_` e JWT com papel diferente de `anon` são recusados por esta configuração.
