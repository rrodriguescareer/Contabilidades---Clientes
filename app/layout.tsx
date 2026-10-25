import type { Metadata, Viewport } from 'next';
import { DM_Sans, Manrope } from 'next/font/google';
import { RegistarServico } from '@/components/registar-servico';
import './globals.css';

// As mesmas do website: DM Sans no corpo, Manrope nos títulos.
const corpo = DM_Sans({
  subsets: ['latin'],
  display: 'swap',
  variable: '--fonte-corpo',
  weight: ['400', '500', '600', '700', '800'],
});

const titulos = Manrope({
  subsets: ['latin'],
  display: 'swap',
  variable: '--fonte-titulos',
  weight: ['500', '600', '700', '800'],
});

export const metadata: Metadata = {
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL || 'https://gestao.rr-contabilidade.com'),
  title: { default: 'Gestão de Clientes · RR.', template: '%s · Gestão RR.' },
  description: 'Centro de administração de clientes, empresas, preços e pagamentos.',
  applicationName: 'Gestão RR.',
  appleWebApp: { capable: true, title: 'Gestão RR.', statusBarStyle: 'black-translucent' },
  icons: {
    icon: [
      { url: '/favicon.svg', type: 'image/svg+xml' },
      { url: '/icone-192.png', sizes: '192x192', type: 'image/png' },
    ],
    apple: '/apple-touch-icon.png',
  },
  robots: { index: false, follow: false },
  // Não é indexada, mas a ligação é partilhada em conversas: vale o cartão.
  openGraph: {
    type: 'website',
    locale: 'pt_PT',
    siteName: 'Gestão RR.',
    title: 'Gestão de clientes',
    description: 'Centro de administração — acesso reservado.',
    images: [{ url: '/og.png', width: 1200, height: 630, alt: 'RR. — Contabilidade · Fiscalidade' }],
  },
};

export const viewport: Viewport = {
  themeColor: '#0A2344',
  width: 'device-width',
  initialScale: 1,
  viewportFit: 'cover',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="pt-PT" className={`${corpo.variable} ${titulos.variable}`}>
      <body>
        <a className="skip" href="#principal">
          Saltar para o conteúdo
        </a>
        {children}
        <RegistarServico />
      </body>
    </html>
  );
}
