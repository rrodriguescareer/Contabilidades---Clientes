import type { NextConfig } from 'next';
const config: NextConfig={poweredByHeader:false,experimental:{serverActions:{bodySizeLimit:"12mb"}}, async redirects(){return [{source:'/demonstracao',destination:'/entrar',permanent:true},{source:'/teste',destination:'/entrar',permanent:true}]}, async headers(){return [{source:'/:path*',headers:[{key:'X-Content-Type-Options',value:'nosniff'},{key:'X-Frame-Options',value:'DENY'},{key:'Referrer-Policy',value:'strict-origin-when-cross-origin'},{key:'X-Robots-Tag',value:'noindex, nofollow'}]}]}};
export default config;
