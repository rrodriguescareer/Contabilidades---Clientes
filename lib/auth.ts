import 'server-only';
import { redirect } from 'next/navigation';
import { configuration, supabase } from './supabase';
import { IS_MANAGEMENT } from './app';
export async function identity() {
  if (!configuration()) redirect('/entrar');
  const client = await supabase();
  const { data: { user } } = await client.auth.getUser();
  if (!user) redirect('/entrar');
  return { client, user };
}
export async function session() {
  const current = await identity();
  if (IS_MANAGEMENT) {
    const { data, error } = await current.client.rpc('is_staff');
    if (error) redirect('/entrar?erro=Base%20de%20dados%20por%20preparar.%20Execute%20a%20migração%20central.');
    if (!data) redirect('/entrar?erro=Esta%20conta%20não%20tem%20acesso%20à%20gestão.');
  }
  return current;
}
