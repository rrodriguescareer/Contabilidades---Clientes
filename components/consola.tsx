import Link from 'next/link';
import { signOut } from '@/lib/auth-actions';
import { Navegacao } from './navegacao';
import { Titulo } from './titulo';
import e from './consola.module.css';

/** Endereço público da plataforma de IRS, para a ligação ao gabinete. */
function enderecoIrs() {
  const valor = process.env.NEXT_PUBLIC_IRS_URL || '';
  return /^https:\/\//.test(valor) ? valor.replace(/\/$/, '') : null;
}

/* Desenhada uma vez no layout: ao navegar entre módulos só o conteúdo muda. */
export function Consola({
  email,
  administrador,
  children,
}: {
  email: string;
  administrador: boolean;
  children: React.ReactNode;
}) {
  return (
    <div className={e.consola}>
      <aside className={e.lateral}>
        <Link href="/app" className={e.marca}>
          <img src="/rr.svg" alt="RR." width={259} height={142} />
          <span className={e.modo}>Gestão</span>
        </Link>

        <Navegacao irs={enderecoIrs()} />

        <div className={e.rodapeLateral}>
          <div className={e.eu}>
            <span className={e.avatar}>{iniciais(email)}</span>
            <div>
              <strong>{administrador ? 'Administrador' : 'Contabilista Certificado'}</strong>
              <span>{email}</span>
            </div>
          </div>
          <form action={signOut}>
            <button className={e.sair}>Sair</button>
          </form>
        </div>
      </aside>

      <div className={e.corpo}>
        <header className={e.topo}>
          <Titulo />
        </header>
        <main className={e.conteudo} id="principal">
          {children}
        </main>
      </div>
    </div>
  );
}

const iniciais = (email: string) => (email.split('@')[0] || '?').slice(0, 2).toUpperCase();

export function Avisos({ erro, mensagem }: { erro?: string; mensagem?: string }) {
  return (
    <>
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
    </>
  );
}

/** Cabeçalho de uma secção dentro de um módulo. */
export function Secao({
  titulo,
  nota,
  acoes,
  children,
}: {
  titulo: string;
  nota?: string;
  acoes?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <section className={e.secao}>
      <div className={e.secaoTitulo}>
        <div className="pilha" style={{ gap: '.125rem' }}>
          <h2>{titulo}</h2>
          {nota && <p>{nota}</p>}
        </div>
        {acoes}
      </div>
      {children}
    </section>
  );
}
