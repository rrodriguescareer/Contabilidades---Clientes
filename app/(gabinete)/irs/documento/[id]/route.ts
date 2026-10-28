import { NextResponse, type NextRequest } from 'next/server';
import { session } from '@/lib/auth';
import { uuid } from '@/lib/data';

/* Abrir ou descarregar um documento do cliente. Uma ligação normal, que o
   navegador abre num separador novo e mostra logo. Cada abertura fica
   registada antes de o ficheiro sair: é o "aberto a" que o cliente vê. */
export async function GET(pedido: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!uuid(id)) return new NextResponse('Documento inválido.', { status: 400 });
  const { client } = await session();

  const { data: caminho, error } = await client.rpc('registar_descarga', { documento: id });
  if (error || typeof caminho !== 'string') {
    return new NextResponse(error?.code === '22023' ? error.message : 'Documento indisponível.', { status: 404 });
  }

  let opcoes: { download: string } | undefined;
  if (pedido.nextUrl.searchParams.has('descarregar')) {
    const { data } = await client.from('documents').select('file_name').eq('id', id).maybeSingle();
    opcoes = { download: data?.file_name || 'documento' };
  }
  const { data: assinado, error: semUrl } = await client.storage
    .from('irs-documents')
    .createSignedUrl(caminho, 60, opcoes);
  if (semUrl || !assinado) return new NextResponse('Não foi possível abrir o documento.', { status: 502 });

  return NextResponse.redirect(assinado.signedUrl, { status: 303, headers: { 'Cache-Control': 'no-store' } });
}
