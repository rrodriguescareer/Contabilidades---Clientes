'use client';
import {usePathname} from 'next/navigation';
import PortalLink from './portal-link';
const modules=[['/app','Visão geral','01'],['/utilizadores','Utilizadores e acessos','02'],['/empresas','Empresas','03'],['/processos','IRS 2026','04'],['/alertas','Alertas e convites','!'],['/descontos','Códigos de desconto','05'],['/faturacao','Faturação','06'],['/pagamentos','Pagamentos','07'],['/configuracao','Configurações','08']];
export default function ManagementNavigation({owner}:{owner:boolean}){
 const path=usePathname();
 return <nav className="admin-navigation" aria-label="Gestão central">{modules.filter(([href])=>owner||['/app','/processos','/alertas'].includes(href)).map(([href,label,num])=><PortalLink key={href} href={href} current={path===href||(href==='/processos'&&path==='/irs')}><span>{num}</span>{label}</PortalLink>)}</nav>;
}
