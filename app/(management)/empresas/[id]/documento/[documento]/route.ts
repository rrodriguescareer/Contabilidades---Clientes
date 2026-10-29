import { NextResponse, type NextRequest } from 'next/server';
import { ownerSession } from '@/lib/auth';
import { uuid } from '@/lib/data';

export const dynamic = 'force-dynamic';

/** Abre um documento do mês enviado no portal Empresas. */
export async function GET(_: NextRequest, { params }: { params: Promise<{ id: string; documento: string }> }) {
  const { id, documento } = await params;
  const { client } = await ownerSession();
  if (!uuid(id) || !uuid(documento)) return new NextResponse('Documento indisponível.', { status: 404 });
  const { data: doc } = await client.from('empresa_documentos').select('caminho').eq('id', documento).eq('company_id', id).maybeSingle();
  if (!doc) return new NextResponse('Documento indisponível.', { status: 404 });
  const { data, error } = await client.storage.from('empresas-documentos').createSignedUrl(doc.caminho, 60);
  if (error || !data?.signedUrl) return new NextResponse('Não foi possível abrir o documento.', { status: 502 });
  const r = NextResponse.redirect(data.signedUrl);
  r.headers.set('Cache-Control', 'private, no-store');
  return r;
}
