import { session } from '@/lib/auth';
import { Lateral } from '@/components/consola';
import { Chegada } from '@/components/chegada';
import e from '@/components/consola.module.css';

export const dynamic = 'force-dynamic';

/* O gabinete do IRS dentro da gestão: o mesmo menu lateral, mas o topo é da
   própria consola, que mostra o nome do cliente quando há um processo aberto. */
export default async function LayoutGabinete({ children }: { children: React.ReactNode }) {
  const { user, context } = await session();
  const administrador = context.email.toLowerCase() === 'contabilidade.rubenrodrigues@gmail.com';
  return (
    <div className={e.consola}>
      <Chegada nome={context.profile.full_name || null} />
      <Lateral email={user.email} administrador={administrador} />
      <div className={e.corpo}>{children}</div>
    </div>
  );
}
