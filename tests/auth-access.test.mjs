import test from 'node:test';
import assert from 'node:assert/strict';
import {signInError} from '../lib/auth-errors.ts';
import {portalContext} from '../lib/portal-context.ts';
test('authentication errors identify the actual action needed without leaking server details',()=>{
 assert.match(signInError('invalid_credentials'),/palavra-passe incorretos/);
 assert.match(signInError('email_not_confirmed'),/não foi confirmado/);
 assert.match(signInError('over_request_rate_limit'),/Aguarde/);
 assert.match(signInError('user_banned'),/bloqueado/);
});
test('an installed context RPC needs one database request',async()=>{
 let calls=0;const context={id:'user-a',email:'a@example.com',is_staff:false,profile:{id:'user-a'},legal_accepted:true};
 const client={async rpc(name){calls++;assert.equal(name,'get_portal_context');return {data:context,error:null};},from(){throw new Error('Unexpected extra lookup');}};
 assert.equal((await portalContext(client,'user-a')).data,context);assert.equal(calls,1);
});
test('permission errors fail closed instead of falling back to a role from metadata',async()=>{
 const client={async rpc(){return {data:null,error:{code:'42501'}};},from(){throw new Error('Fallback should not run');}};
 const result=await portalContext(client,'user-a');assert.equal(result.data,null);assert.equal(result.error.code,'42501');
});
