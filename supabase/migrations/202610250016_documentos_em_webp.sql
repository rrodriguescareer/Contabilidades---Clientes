-- Os documentos fiscais chegam quase sempre como fotografias de telemóvel:
-- 4000px de largura e vários megabytes para um recibo que se lê a 2600px.
-- A aplicação passa a convertê-las para WebP antes de as guardar, por isso o
-- balde tem de aceitar esse tipo. Os PDF continuam a entrar como vêm.

begin;

update storage.buckets
set allowed_mime_types = array['application/pdf','image/jpeg','image/png','image/webp']
where id = 'irs-documents';

commit;
