# Contabilidades — Gestão de Clientes

Aplicação privada Next.js/TypeScript para o contabilista, com módulos IRS, utilizadores, empresas, descontos e pagamentos. Partilha Supabase com o [Portal IRS](https://github.com/rrodriguescareer/Contabilidades---IRS). A administração pertence à conta confirmada `contabilidade.rubenrodrigues@gmail.com`. Os contabilistas por si convidados acedem ao acompanhamento IRS; a gestão de acessos e configurações permanece reservada ao administrador.

## Atualizar a instalação existente

Executar **`supabase/update-current.sql` completo** no SQL Editor do mesmo projeto Supabase. Aplica apenas as migrações 005–009 em falta e pode ser repetido sem apagar ou reiniciar dados. No fim apresenta o diagnóstico da conta do contabilista. Não repetir a instalação inicial.

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
- Campanha IRS 2026 com processos com agregado, rendimentos, documentos privados, mensagens, progresso e alertas de 2FA.
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

## Administração e campanha IRS 2026

A Gestão tem um layout administrativo próprio e persistente: utilizadores, empresas, acompanhamento IRS, descontos, faturas, pagamentos e configurações. O Portal IRS mantém a experiência do cliente. O registo público nunca atribui funções profissionais; apenas o administrador pode convidar contabilistas e associar utilizadores a empresas. Não existe seleção de ano na interface. A campanha chama-se IRS 2026; o campo técnico de ano de rendimentos mantém-se para integridade dos dados já existentes. Não foi programada qualquer limpeza ou envio de emails para o próximo ano.

Executar a atualização `supabase/update-current.sql` do repositório Gestão no Supabase partilhado. Pode repetir sem apagar dados. A migração 009 prepara a campanha, papéis geridos, configurações e otimiza as políticas de leitura.

Nas DUAS aplicações Vercel, definir `SUPABASE_SECRET_KEY` (ou service role) e a mesma `INTEGRATION_ENCRYPTION_KEY`, privada, de 64 caracteres hexadecimais. Gerar uma vez com `openssl rand -hex 32`, guardar num gestor de segredos e copiar apenas para as variáveis privadas do Vercel; não enviar para o GitHub ou para o chat. Não substituir esta chave depois de guardar credenciais sem uma migração de cifragem. Depois de Redeploy, configurar Merchant key, segredo webhook e versão da API em Gestão → Configurações. Em Empresas, cada empresa permite guardar a sua credencial Cegid própria; a ligação operacional Cegid continua pendente.

A faturação central apresenta os documentos já associados às contas e os pagamentos registados. O módulo Empresas operacional e a emissão automática de faturas Cegid não foram implementados nesta alteração. Não são apresentadas faturas fictícias.

O modal IRS mostra rubricas, desconto e confirmação. O pagamento com cartão decorre no checkout hospedado da Revolut, após confirmação no modal. Não é usado um iframe não verificado para recolher cartões. O retorno mostra de imediato o estado persistido; a consulta externa ocorre depois do carregamento. Só confirmação autenticada do fornecedor permite liquidar a cobrança.

## Desempenho e diagnóstico

O menu persiste durante a navegação; as páginas privadas são dinâmicas e não partilham caches de dados entre utilizadores. A sessão e a navegação do cliente são obtidas numa única RPC autorizada pelo JWT verificado no PostgREST. O conteúdo é carregado por separador. A compatibilidade com instalações antigas verifica explicitamente a identidade no Auth. As listagens calculam as contas autorizadas uma vez por consulta. A pré-carga só ocorre com intenção de navegação (foco ou passagem do ponteiro), evitando descarregar todos os módulos.

Na Gestão → Configurações, «Medir tempo de ligação» mostra o tempo total, a autorização no servidor e a região Vercel. Os logs Vercel `rr_backend_timing` identificam pedidos Supabase acima de 750 ms; `rr_login_timing` mede a etapa de autenticação. Nenhum destes logs inclui emails, senhas, tokens ou parâmetros de consulta. Ainda é necessário medir o serviço remoto antes de afirmar que a latência de produção ficou resolvida. A região Vercel deve ser alinhada com a região real do Supabase após verificar ambas.
