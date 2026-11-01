import type { NextConfig } from 'next';
/* Banda larga: as imagens de /public ficam uma semana no browser (antes eram
   pedidas de novo em cada página), e uma página já aberta é reutilizada durante
   30 segundos ao voltar a ela, em vez de se pedir outra vez ao servidor. */
const config: NextConfig={poweredByHeader:false,experimental:{useTypeScriptCli:false,serverActions:{bodySizeLimit:"12mb"},staleTimes:{dynamic:30,static:300}}, async redirects(){return [{source:'/demonstracao',destination:'/entrar',permanent:true},{source:'/teste',destination:'/entrar',permanent:true}]}, async headers(){return [{source:'/:path*',headers:[{key:'X-Content-Type-Options',value:'nosniff'},{key:'X-Frame-Options',value:'DENY'},{key:'Referrer-Policy',value:'strict-origin-when-cross-origin'},{key:'X-Robots-Tag',value:'noindex, nofollow'},{key:'Permissions-Policy',value:'camera=(), microphone=(), geolocation=(), payment=(self "https://js.stripe.com")'}]},{source:'/:ficheiro*(svg|png|webp|jpg|jpeg|ico)',headers:[{key:'Cache-Control',value:'public, max-age=604800, stale-while-revalidate=2592000'}]}]}};
export default config;
