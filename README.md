# Contabilidades — Gestão de Clientes

Aplicação privada Next.js/TypeScript para o contabilista, com módulos IRS, utilizadores, empresas, descontos e pagamentos. Partilha Supabase com o [Portal IRS](https://github.com/rrodriguescareer/Contabilidades---IRS). A Gestão é exclusiva da conta confirmada `contabilidade.rubenrodrigues@gmail.com`, também autorizada em `staff_users`.

## Atualizar a instalação existente

Executar **`supabase/update-current.sql` completo** no SQL Editor do mesmo projeto Supabase. Aplica apenas as migrações 005–008 em falta e pode ser repetido sem apagar ou reiniciar dados. No fim apresenta o diagnóstico da conta do contabilista. Não repetir a instalação inicial.

Para uma base vazia, usar `supabase/install.sql`. Estes ficheiros são gerados a partir das migrações com `npm run db:bundle` e ficam fora da pasta de migrações para não serem aplicados duas vezes pela CLI.

O [guia de ativação](docs/ativacao.md) explica email RR, conta do contabilista, Vercel, convites, Revolut, preços e conservação de documentos. As configurações e migrações remotas não foram aplicadas por este desenvolvimento, que não tem acesso administrativo ao projeto Supabase/Vercel.

## Vercel

Importar `main`, framework **Next.js**, raiz do repositório, Node.js **24**, build `npm run build`. Preencher as variáveis de `.env.example`. As variáveis básicas são:

- `NEXT_PUBLIC_SUPABASE_URL=https://rllajahyovpzndbbyvcd.supabase.co`
- `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (ou `NEXT_PUBLIC_SUPABASE_ANON_KEY`)
- `NEXT_PUBLIC_SITE_URL`: URL desta Gestão
- `NEXT_PUBLIC_IRS_URL`: URL do Portal IRS

As duas aplicações usam o mesmo Supabase, com URLs próprias. Não precisam de duas integrações automáticas Vercel/Supabase. A sessão não é partilhada automaticamente entre domínios. As chaves administrativas e Merchant são privadas e nunca usam prefixo `NEXT_PUBLIC_`.

## Funcionalidades

- Registo IRS e abertura inicial automáticos, sem aprovação manual.
- Consulta/pesquisa paginada de utilizadores, estados dos convites aceites, bloqueio de acesso e eliminação da autenticação com conservação fiscal.
- Empresas associadas a um ou vários utilizadores e controlo de acessos por empresa.
- Processos anuais IRS com agregado, rendimentos, documentos privados, mensagens, progresso e alertas de 2FA.
- Códigos com restrições combináveis, clientes gratuitos e descontos obrigatórios.
- Consulta/reconciliação de ordens Revolut, orçamento discriminado e proteção contra confirmações falsas ou repetidas.
- Documentos originais em Storage privado, com reutilização de bytes idênticos dentro de cada processo.

A plataforma operacional Empresas, integração Cegid, cofre de senhas fiscais, OCR e pagamentos de impostos à AT não estão implementados. Os convites confirmam a identidade do familiar, sem conceder acesso aos dados fiscais dos restantes membros. Os dados pessoais ainda não têm snapshots históricos completos por exercício.

O envio com remetente RR requer Custom SMTP no Supabase. A cobrança Revolut permanece desativada por configuração até validação da conta Merchant e versão da API. Os fornecedores reais não foram validados neste ambiente; as verificações automáticas usam apenas dados isolados locais e não publicam cenários nem contas fictícias nos portais.

## Verificação local

```sh
npm ci
npm run typecheck
npm run build
npm run test:auth
npm run test:dashboard
npm run test:config
npm run test:validation
npm run test:revolut
npm run test:db
npm run test:platform
npm run test:install
npm run test:upgrade
```

Para desenvolvimento local: preencher `.env.local` e executar `npm run dev -- --port 3001`. Os antigos caminhos `/teste` e `/demonstracao` apenas redirecionam para `/entrar`.
