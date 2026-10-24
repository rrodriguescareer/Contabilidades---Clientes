import {session} from '@/lib/auth';
import {signOut} from '@/lib/auth-actions';
import ManagementNavigation from '@/components/management-navigation';
export const dynamic='force-dynamic';
export default async function AdministrativeLayout({children}:{children:React.ReactNode}){
 const {user,context}=await session();const owner=context.email.toLowerCase()==='contabilidade.rubenrodrigues@gmail.com';
 return <div className="admin-shell"><aside className="admin-sidebar"><a className="admin-brand" href="/app"><img src="/rr-logo.svg" alt="RR." width="56" height="34"/><span>GESTÃO<small>Centro de administração</small></span></a><div className="admin-role">{owner?'ADMINISTRADOR':'CONTABILISTA CERTIFICADO'}</div><ManagementNavigation owner={owner}/><div className="admin-sidebar-foot"><span>{user.email}</span><form action={signOut}><button>Terminar sessão</button></form></div></aside><div className="admin-body"><header className="admin-topbar"><span>RR / Gestão central</span><span className="admin-status">Área profissional</span></header><main className="admin-content" id="main">{children}</main><footer className="admin-footer">RR · Gestão de clientes e serviços</footer></div></div>;
}
