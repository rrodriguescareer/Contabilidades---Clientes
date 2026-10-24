export default function ManagementShell({title,children,error,message}:{title:string;children:React.ReactNode;error?:string;message?:string}){
 return <><header className="admin-heading"><span className="eyebrow">ADMINISTRAÇÃO</span><h1>{title}</h1></header>{error&&<div className="alert error" role="alert">{error}</div>}{message&&<div className="alert" role="status">{message}</div>}{children}</>;
}
