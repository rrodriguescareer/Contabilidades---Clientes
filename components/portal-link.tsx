'use client';
import {useRef} from 'react';
import {useRouter} from 'next/navigation';
import Link,{useLinkStatus} from 'next/link';
function Pending(){const {pending}=useLinkStatus();return pending?<span className="navigation-spinner" role="status" aria-label="A carregar"/>:null;}
export default function PortalLink({href,children,className,current}:{href:string;children:React.ReactNode;className?:string;current?:boolean}){
 const router=useRouter(),timer=useRef<ReturnType<typeof setTimeout>|null>(null);
 function cancel(){if(timer.current)clearTimeout(timer.current);}
 return <Link href={href} prefetch={false} className={className} aria-current={current?'page':undefined} onPointerEnter={()=>{cancel();timer.current=setTimeout(()=>router.prefetch(href),180);}} onPointerLeave={cancel} onFocus={()=>router.prefetch(href)} onClick={cancel}>{children}<Pending/></Link>;
}
