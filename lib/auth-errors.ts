export function signInError(code?:string){
 if(code==='email_not_confirmed')return 'O email ainda não foi confirmado. Abra a ligação de ativação recebida por email.';
 if(code==='invalid_credentials')return 'Email ou palavra-passe incorretos. Se ainda não criou esta conta, crie-a primeiro ou utilize a recuperação de acesso.';
 if(code==='over_request_rate_limit'||code==='over_email_send_rate_limit')return 'Foram feitas várias tentativas. Aguarde um pouco antes de tentar novamente.';
 if(code==='user_banned')return 'Acesso bloqueado. Contacte o responsável.';
 return 'Não foi possível comunicar com o serviço de autenticação. Tente novamente dentro de instantes.';
}
