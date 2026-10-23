'use client';
import Link from 'next/link';
export default function ErrorPage({reset}:{reset:()=>void}){return <main id="main" className="legal-layout"><section className="panel"><h1>Não foi possível concluir o pedido.</h1><p>Tente novamente. Se o problema continuar, contacte o profissional.</p><div className="auth-links"><button className="primary" onClick={reset}>Tentar novamente</button><Link href="/entrar">Voltar à entrada</Link></div></section></main>;}
