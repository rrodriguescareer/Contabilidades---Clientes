import { redirect } from 'next/navigation';
import { configuration } from '@/lib/supabase';
export const dynamic='force-dynamic';
export default function Page(){redirect(configuration()?'/app':'/demonstracao');}
