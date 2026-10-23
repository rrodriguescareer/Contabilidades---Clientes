import type { Metadata } from 'next';
import { APP_TITLE, IS_MANAGEMENT } from '@/lib/app';
import './globals.css';
export const metadata: Metadata = { title: `${APP_TITLE} · RR.`, description: 'Área privada de clientes e processos fiscais.', robots:{index:false,follow:false} };
export default function RootLayout({children}:{children:React.ReactNode}) { return <html lang="pt-PT"><body className={IS_MANAGEMENT?'management':''}><a className="skip" href="#main">Saltar para o conteúdo</a>{children}</body></html>; }
