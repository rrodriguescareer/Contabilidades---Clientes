'use client';
import Link,{useLinkStatus} from 'next/link';
function Pending(){const {pending}=useLinkStatus();return pending?<span className="navigation-spinner" role="status" aria-label="A carregar"/>:null;}
export default function PortalLink({href,children,className,current}:{href:string;children:React.ReactNode;className?:string;current?:boolean}){
 return <Link href={href} prefetch={false} className={className} aria-current={current?'page':undefined}>{children}<Pending/></Link>;
}
