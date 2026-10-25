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

1. **SMTP**: Project Settings → Authentication → SMTP Settings.
2. **URL Configuration**: o *Site URL* e os *Redirect URLs* têm de incluir
   `https://irs.rr-contabilidade.com` e `https://gestao.rr-contabilidade.com`.
3. Só depois de um email de teste chegar é que se liga
   `AUTH_EMAIL_BRANDING_READY=true` nas duas aplicações Vercel. Essa variável é
   o que mantém o registo e a recuperação fechados enquanto o email não presta.
