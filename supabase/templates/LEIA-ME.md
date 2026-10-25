# Emails de autenticação

Estes cinco ficheiros são os templates que o Supabase envia. **São gerados** a
partir de `marca/emails.mjs` — editar aqui à mão perde-se na próxima
distribuição. Para os mudar, muda-se o gerador e corre-se:

```bash
cd ../../../marca && npm run distribuir
```

| Ficheiro | Onde colar no Supabase |
| --- | --- |
| `confirm-signup.html` | Authentication → Emails → **Confirm signup** |
| `invite.html` | **Invite user** |
| `recovery.html` | **Reset password** |
| `email-change.html` | **Change email address** |
| `magic-link.html` | **Magic link** |

## Porque é que não têm a tipografia da marca

Metade dos clientes de email ignora webfonts, e o Outlook ignora-as sempre. Um
email que depende da DM Sans fica pior nos sítios onde ela não carrega do que
um que nunca contou com ela. O que mantém a marca aqui é a cor, a assinatura
no topo e o tom do texto — não a letra.

Pela mesma razão o desenho é feito com tabelas e estilos em linha: é o que o
Outlook percebe.

## A assinatura

Os emails carregam `https://www.rr-contabilidade.com/assets/assinatura-email.png`.
É a versão branca, sobre a faixa escura — de propósito: um logótipo escuro em
PNG transparente desaparece nos clientes que forçam modo escuro.

Esse endereço tem de continuar a responder. Se o website mudar de sítio, estes
templates mostram um quadrado vazio.

## O que falta do lado do Supabase

O domínio `rr-contabilidade.com` está verificado no Resend (região
`eu-west-1`), com DKIM e os dois CNAME de Return-Path a passar.

### 1. SMTP

Project Settings → Authentication → SMTP Settings:

| Campo | Valor |
| --- | --- |
| Host | `smtp.resend.com` |
| Port | `465` |
| Username | `resend` |
| Password | a chave de API do Resend (permissão *Sending access*) |
| Sender email | `contabilidade@rr-contabilidade.com` |
| Sender name | `Rúben Rodrigues · Contabilidade` |

A porta 465 é SMTPS — ligação cifrada desde o início. As portas 587 e 2587
também servem, mas usam STARTTLS, que começa em claro.

### 2. Limite de envio

Authentication → Rate Limits. Por omissão o Supabase deixa passar poucos
emails por hora, porque conta com o serviço interno dele. Com SMTP próprio
esse limite pode subir — senão, em campanha, os clientes ficam à espera do
email de confirmação sem perceber porquê.

### 3. URL Configuration

*Site URL*: `https://irs.rr-contabilidade.com`

*Redirect URLs*: esse e `https://gestao.rr-contabilidade.com`.

### 4. Só no fim

Depois de um email de teste chegar mesmo, liga-se
`AUTH_EMAIL_BRANDING_READY=true` nas duas aplicações Vercel. Essa variável é o
que mantém o registo e a recuperação fechados enquanto o email não presta —
ligá-la antes de confirmar abre o registo com o email partido.

### Recomendado, não obrigatório

Não há DMARC no domínio. Um TXT em `_dmarc` com
`v=DMARC1; p=none; rua=mailto:contabilidade.rubenrodrigues@gmail.com`
melhora a entrega e dá relatórios de quem anda a enviar em teu nome.
