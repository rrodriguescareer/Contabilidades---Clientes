import type { Metadata, Viewport } from 'next';
import { Inter } from 'next/font/google';
import { RegistarServico } from '@/components/registar-servico';
import './globals.css';

const inter = Inter({
  subsets: ['latin'],
  display: 'swap',
  variable: '--fonte-inter',
  weight: ['400', '500', '600', '700', '800'],
});

export const metadata: Metadata = {
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
};

export const viewport: Viewport = {
  themeColor: '#0A2344',
  width: 'device-width',
  initialScale: 1,
  viewportFit: 'cover',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="pt-PT" className={inter.variable}>
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
