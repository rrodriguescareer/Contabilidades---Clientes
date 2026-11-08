import { NextResponse } from 'next/server';
import { ownerSession } from '@/lib/auth';
import { adminClient } from '@/lib/admin-client';
import { uuid } from '@/lib/data';

/* Abre um documento recebido, com um endereço que dura dois minutos. */
export async function GET(_: Request, { params }: { params: Promise<{ id: string }> }) {
  const { client } = await ownerSession();
  const { id } = await params;
  if (!uuid(id)) return new NextResponse('Documento inválido.', { status: 400 });
  const { data } = await client.from('empresa_documentos').select('caminho').eq('id', id).maybeSingle();
  if (!data) return new NextResponse('Documento indisponível.', { status: 404 });
  const { data: url } = await adminClient().storage.from('empresas-documentos').createSignedUrl(data.caminho, 120);
  if (!url?.signedUrl) return new NextResponse('Documento indisponível.', { status: 404 });
  return NextResponse.redirect(url.signedUrl);
}
