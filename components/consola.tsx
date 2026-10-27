import Link from 'next/link';
import { Suspense } from 'react';
import { contagensDoGabinete } from '@/lib/irs-actions';
import { Chegada } from './chegada';
import { signOut } from '@/lib/auth-actions';
import { Navegacao } from './navegacao';
import { Titulo } from './titulo';
import e from './consola.module.css';

/* O menu lateral, desenhado uma vez. Serve as páginas da gestão e o gabinete
   do IRS, que tem o seu próprio topo (o nome do cliente, o voltar). */
export async function Lateral({ email, administrador }: { email: string; administrador: boolean }) {
  const contagens = await contagensDoGabinete().catch(() => ({}));
  return (
    <aside className={e.lateral}>
      <Link href="/irs" className={e.marca}>
        <img src="/rr.svg" alt="RR." width={259} height={142} />
        <span className={e.modo}>Gabinete</span>
      </Link>

      <Suspense fallback={null}>
        <Navegacao contagens={contagens} />
      </Suspense>

      <div className={e.rodapeLateral}>
        <div className={e.eu}>
          <span className={e.avatar}>RM</span>
          <div>
            <strong>{administrador ? 'Rúben Meirinho Rodrigues' : 'Contabilista Certificado'}</strong>
            <span>{email}</span>
          </div>
        </div>
        <form action={signOut}>
          <button className={e.sair}>Sair</button>
        </form>
      </div>
    </aside>
  );
}

/* As páginas da gestão: menu, topo com o título e o conteúdo. */
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
      <Chegada />
      <Lateral email={email} administrador={administrador} />
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
