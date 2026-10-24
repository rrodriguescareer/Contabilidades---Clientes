import Link from 'next/link';
import { configuration } from './supabase';
import a from './auth-view.module.css';

type Props = {
  children: React.ReactNode;
  titulo: string;
  descricao: string;
  mensagem?: string;
  erro?: string;
  /** Ligações por baixo do formulário. */
  rodape?: React.ReactNode;
};

/* Ecrã partilhado por entrar, registar, recuperar e definir palavra-passe.
   À esquerda a marca, à direita o formulário; no telemóvel só o formulário. */
export function EcraAutenticacao({ children, titulo, descricao, mensagem, erro, rodape }: Props) {
  const pronto = Boolean(configuration());

  return (
    <main id="principal" className={a.ecra}>
      <section className={a.marca} aria-hidden="true">
        <img src="/rr-branco.svg" alt="" width={294} height={195} />
        <div className={a.marcaTexto}>
          <h2>Os seus clientes, num só lugar.</h2>
          <p>
            Acessos, empresas, credenciais, descontos e pagamentos. O acompanhamento dos processos de IRS vive na
            plataforma do IRS, no espaço do contabilista.
          </p>
        </div>
        <small>Rúben Meirinho Rodrigues · Contabilista Certificado n.º 145854</small>
      </section>

      <section className={a.coluna}>
        <div className={a.cartao}>
          <Link href="/" className={a.logo}>
            <img src="/rr.svg" alt="RR." width={294} height={195} />
          </Link>

          <div className="pilha pilha-2">
            <h1>{titulo}</h1>
            <p className="suave">{descricao}</p>
          </div>

          {erro && (
            <p className="aviso aviso-critico" role="alert">
              {erro}
            </p>
          )}
          {mensagem && (
            <p className="aviso aviso-positivo" role="status">
              {mensagem}
            </p>
          )}

          {pronto ? (
            children
          ) : (
            <div className="aviso aviso-critico pilha pilha-2" role="alert">
              <strong>Serviço temporariamente indisponível</strong>
              <p>Não foi possível estabelecer ligação. Tente mais tarde ou contacte-me por email.</p>
              <a href="mailto:contabilidade.rubenrodrigues@gmail.com">contabilidade.rubenrodrigues@gmail.com</a>
            </div>
          )}

          {rodape && <div className={a.ligacoes}>{rodape}</div>}

          <div className={a.legal}>
            <span>Acesso restrito · Rúben Meirinho Rodrigues</span>
          </div>
        </div>
      </section>
    </main>
  );
}
