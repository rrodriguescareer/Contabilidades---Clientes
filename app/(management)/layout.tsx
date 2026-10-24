import { session } from '@/lib/auth';
import { Consola } from '@/components/consola';

export const dynamic = 'force-dynamic';

export default async function LayoutAdministrativo({ children }: { children: React.ReactNode }) {
  const { user, context } = await session();
  const administrador = context.email.toLowerCase() === 'contabilidade.rubenrodrigues@gmail.com';
  return (
    <Consola email={user.email} administrador={administrador}>
      {children}
    </Consola>
  );
}
