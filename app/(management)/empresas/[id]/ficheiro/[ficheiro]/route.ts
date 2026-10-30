import { NextResponse } from 'next/server';
import { ownerSession } from '@/lib/auth';
import { uuid } from '@/lib/data';

export const dynamic = 'force-dynamic';

/** Abre um ficheiro do pessoal ou dos impostos de uma empresa. */
export async function GET(_: Request, { params }: { params: Promise<{ id: string; ficheiro: string }> }) {
  const { id, ficheiro } = await params;
  const { client } = await ownerSession();
  if (!uuid(id) || !uuid(ficheiro)) return new NextResponse('Ficheiro indisponível.', { status: 404 });
  const { data: f } = await client.from('empresa_ficheiros').select('caminho').eq('id', ficheiro).eq('company_id', id).maybeSingle();
  if (!f) return new NextResponse('Ficheiro indisponível.', { status: 404 });
  const { data, error } = await client.storage.from('empresas-ficheiros').createSignedUrl(f.caminho, 60);
  if (error || !data?.signedUrl) return new NextResponse('Não foi possível abrir.', { status: 502 });
  const r = NextResponse.redirect(data.signedUrl);
  r.headers.set('Cache-Control', 'private, no-store');
  return r;
}
