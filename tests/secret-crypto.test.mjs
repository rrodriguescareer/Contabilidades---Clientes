import test from 'node:test';
import assert from 'node:assert/strict';
import {encryptSecret,decryptSecret} from '../lib/secret-crypto.ts';
test('integration secrets require a key, hide plaintext and bind each ciphertext to its company/provider',()=>{
 const previous=process.env.INTEGRATION_ENCRYPTION_KEY;
 try{
 delete process.env.INTEGRATION_ENCRYPTION_KEY;assert.throws(()=>encryptSecret('fixture-api-value','cegid:company-a'));
 process.env.INTEGRATION_ENCRYPTION_KEY='ab'.repeat(32);
 const encrypted=encryptSecret('fixture-api-value','cegid:company-a');assert.ok(!encrypted.includes('fixture-api-value'));
 assert.equal(decryptSecret(encrypted,'cegid:company-a'),'fixture-api-value');assert.throws(()=>decryptSecret(encrypted,'cegid:company-b'));
 const parts=encrypted.split('.');parts[2]=Buffer.alloc(16).toString('base64url');assert.throws(()=>decryptSecret(parts.join('.'),'cegid:company-a'));
 process.env.INTEGRATION_ENCRYPTION_KEY='cd'.repeat(32);assert.throws(()=>decryptSecret(encrypted,'cegid:company-a'));
 }finally{if(previous===undefined)delete process.env.INTEGRATION_ENCRYPTION_KEY;else process.env.INTEGRATION_ENCRYPTION_KEY=previous;}
});
