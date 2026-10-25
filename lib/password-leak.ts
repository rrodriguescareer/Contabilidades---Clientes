import { createHash } from 'node:crypto';

/* Rejeita palavras-passe que já apareceram em fugas de dados.
 *
 * O Supabase tem isto embutido, mas só no plano Pro. O mecanismo que ele usa
 * — a API Pwned Passwords do HaveIBeenPwned — é pública e gratuita, por isso
 * fazemos a verificação aqui.
 *
 * A palavra-passe nunca sai daqui. Calcula-se o SHA-1, enviam-se apenas os
 * cinco primeiros caracteres do resultado, e o serviço devolve todos os
 * sufixos que começam por esse prefixo — tipicamente umas centenas. A
 * comparação é feita neste servidor. É o modelo de k-anonimato descrito pelo
 * próprio serviço.
 *
 * O SHA-1 aqui não é para guardar nada: é o formato que a API exige. As
 * palavras-passe continuam guardadas pelo Supabase com bcrypt.
 *
 * Sem o guarda `server-only`: isto não toca em cookies nem em segredos, e quem
 * o chama já são ações `use server`. Sem o guarda, dá para testar em Node.
 */

const ENDERECO = 'https://api.pwnedpasswords.com/range/';
const ESPERA_MAXIMA = 2500;

export async function senhaComprometida(senha: string): Promise<boolean> {
  if (!senha) return false;

  const impressao = createHash('sha1').update(senha, 'utf8').digest('hex').toUpperCase();
  const prefixo = impressao.slice(0, 5);
  const sufixo = impressao.slice(5);

  try {
    const resposta = await fetch(`${ENDERECO}${prefixo}`, {
      // Add-Padding enche a resposta com entradas falsas, para o tamanho do
      // corpo não denunciar quantas vezes este prefixo aparece.
      headers: { 'Add-Padding': 'true', 'User-Agent': 'RR-Contabilidade' },
      signal: AbortSignal.timeout(ESPERA_MAXIMA),
      cache: 'no-store',
    });
    if (!resposta.ok) return false;

    const corpo = await resposta.text();
    for (const linha of corpo.split('\n')) {
      const [candidato, contagem] = linha.trim().split(':');
      // O enchimento vem com contagem 0; só conta uma ocorrência real.
      if (candidato === sufixo && Number(contagem) > 0) return true;
    }
    return false;
  } catch {
    // Serviço em baixo ou lento: não se tranca ninguém à porta por isso.
    // O mínimo de 12 caracteres continua a ser exigido.
    return false;
  }
}

export const AVISO_SENHA_COMPROMETIDA =
  'Esta palavra-passe já apareceu em fugas de dados conhecidas. Escolha outra que não use em mais lado nenhum.';
