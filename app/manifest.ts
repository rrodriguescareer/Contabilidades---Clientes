import type { MetadataRoute } from 'next';

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: 'Gestão de Clientes · RR.',
    short_name: 'Gestão RR.',
    description: 'Centro de administração de clientes, empresas, preços e pagamentos.',
    id: '/gestao',
    start_url: '/app',
    scope: '/',
    display: 'standalone',
    background_color: '#0A2344',
    theme_color: '#0A2344',
    lang: 'pt-PT',
    icons: [
      { src: '/icone-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
      { src: '/icone-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
      { src: '/icone-maskable-192.png', sizes: '192x192', type: 'image/png', purpose: 'maskable' },
      { src: '/icone-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
    ],
  };
}
