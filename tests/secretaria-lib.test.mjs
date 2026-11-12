import test from 'node:test';
import assert from 'node:assert/strict';
import {comporEmail,interpretarFolha,lerData,lerPeriodo,lerValor,limiteDoPeriodo,limiteSugerido,periodoDe,cadenciaTexto} from '../lib/secretaria.ts';

test('valores: formatos português e inglês, negativos e lixo',()=>{
 assert.equal(lerValor('123,45 €'),12345);
 assert.equal(lerValor('1.234,56'),123456);
 assert.equal(lerValor('1,234.56'),123456);
 assert.equal(lerValor('1 234,5'),123450);
 assert.equal(lerValor('1.234'),123400);
 assert.equal(lerValor('12.5'),1250);
 assert.equal(lerValor('-39,90'),-3990);
 assert.equal(lerValor('abc'),null);
 assert.equal(lerValor(''),null);
});

test('datas: os formatos habituais, e nada que não exista no calendário',()=>{
 assert.equal(lerData('15/10/2026'),'2026-10-15');
 assert.equal(lerData('5-1-26'),'2026-01-05');
 assert.equal(lerData('15.10.2026 00:00'),'2026-10-15');
 assert.equal(lerData('2026-10-15T00:00:00'),'2026-10-15');
 assert.equal(lerData('46310'),'2026-10-15');
 assert.equal(lerData('46316,5'),'2026-10-21','um número de série do Excel com horas');
 assert.equal(lerData('31/02/2026'),null);
 assert.equal(lerData('2026-13-01'),null);
 assert.equal(lerData('amanhã'),null);
});

test('importação: encontra o cabeçalho, lê as linhas e explica as que não entram',()=>{
 const folha=[
  ['Relatório de documentos por lançar'],[],
  ['Fornecedor','Tipo de documento','N.º do documento','Data do documento','Valor (€)','Banco'],
  ['EDP Comercial','Fatura','FT 2026/1','15/10/2026','123,45',''],
  ['Worten','Nota de crédito','NC 7','2026-10-21','-39,90',''],
  ['Extrato de outubro','Extrato bancário','','','','Millennium'],
  ['','Fatura','FT 9','15/10/2026','1',''],
  ['Galp','Fatura','FT 3','32/10/2026','10',''],
  ['Total','','','','94,55',''],
  ['','','','','',''],
 ];
 const r=interpretarFolha(folha);
 assert.equal(r.linhas.length,3);
 assert.deepEqual(r.linhas[0],{descricao:'EDP Comercial',tipo:'FT',numero:'FT 2026/1',data:'2026-10-15',valor_cents:12345,banco:null});
 assert.equal(r.linhas[1].tipo,'NC');assert.equal(r.linhas[1].valor_cents,-3990);
 assert.equal(r.linhas[2].tipo,'EB');assert.equal(r.linhas[2].data,null);assert.equal(r.linhas[2].banco,'Millennium');
 assert.deepEqual(r.recusadas.map(x=>x.linha),[7,8]);
 assert.match(r.recusadas[1].motivo,/data inválida/);

 assert.equal(interpretarFolha([['a','b'],['1','2']]).linhas.length,0);
 assert.match(interpretarFolha([['a','b'],['1','2']]).recusadas[0].motivo,/cabeçalho/);
 // Sem coluna de tipo: com banco é movimento, sem banco é fatura.
 const semTipo=interpretarFolha([['Descrição','Valor','Banco'],['Transferência X','10','BPI'],['Fornecedor Y','20','']]);
 assert.deepEqual(semTipo.linhas.map(l=>l.tipo),['MB','FT']);
});

test('o email: variáveis no assunto e no texto, e a lista por categoria no seu lugar',()=>{
 const pendencias=[
  {id:'1',periodo:'2026-10-01',tipo:'FT',descricao:'EDP',numero:'FT 1',data_documento:'2026-10-15',valor_cents:12345,banco:null},
  {id:'2',periodo:'2026-09-01',tipo:'EB',descricao:'Extrato',numero:null,data_documento:null,valor_cents:null,banco:'BPI'},
 ];
 const e=comporEmail({tipo:'pedido',assunto:'Em falta — {{cliente}} ({{periodo}})',corpo:'Exmos. Senhores,\n\nFaltam {{numero}} documentos.\n\n{{lista}}\n\nAté {{prazo}}.\n\n{{remetente}}',empresa:'ACME, Lda',contacto:'Ana',pendencias,diaLimite:'2026-11-20'});
 assert.equal(e.assunto,'Em falta — ACME, Lda (setembro a outubro de 2026)');
 assert.equal(e.paragrafos[1],'Faltam 2 documentos.');
 // O Intl separa o valor do € com um espaço que não quebra a linha.
 assert.equal(e.paragrafos[2].lista,'Faturas em falta');
 assert.deepEqual(e.paragrafos[2].itens.map(x=>x.replace(/\u00a0/g,' ')),['15/10/2026 – Fatura FT 1: EDP – 123,45 €']);
 assert.equal(e.paragrafos[3].lista,'Bancos');
 assert.equal(e.paragrafos[4],'Até 20/11/2026.');
 assert.match(e.paragrafos[5],/106297/);
 assert.equal(periodoDe([{...pendencias[0],periodo:'2025-12-01'},pendencias[0]]),'dezembro de 2025 a outubro de 2026');
});

test('períodos, limites e calendário',()=>{
 const m=lerPeriodo('mensal','2026-01');
 assert.equal(m.desde,'2026-01-01');assert.equal(m.anterior,'2025-12');assert.equal(m.seguinte,'2026-02');
 const t=lerPeriodo('trimestral','2026-T4');
 assert.equal(t.desde,'2026-10-01');assert.equal(t.ate,'2026-12-01');assert.equal(t.seguinte,'2027-T1');
 assert.equal(lerPeriodo('mensal','2026-13').chave.length,7,'um mês inválido cai no mês anterior ao de hoje');
 assert.equal(lerPeriodo().modo,'todos');
 assert.equal(limiteDoPeriodo('2026-12-01',10),'2027-01-10');
 assert.ok(limiteSugerido(10,['2020-01'])>=new Date().toISOString().slice(0,10),'nunca sugere um dia já passado');
 assert.equal(cadenciaTexto({modo:'uteis',intervalo:3,hora:9}),'De 3 em 3 dias úteis às 09:00');
 assert.equal(cadenciaTexto({modo:'semana',dias:{1:9,4:15}}),'Seg 09:00 · Qui 15:00');
});
