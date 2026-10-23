import test from 'node:test';
import assert from 'node:assert/strict';
import {configuration} from '../lib/public-config.ts';
const names=['NEXT_PUBLIC_SUPABASE_URL','SUPABASE_URL','NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY','NEXT_PUBLIC_SUPABASE_ANON_KEY','SUPABASE_PUBLISHABLE_KEY','SUPABASE_ANON_KEY'];
const jwt=role=>'header.'+Buffer.from(JSON.stringify({role})).toString('base64url')+'.test-fixture-only';
function run(env,check){const saved=Object.fromEntries([...names,'NODE_ENV'].map(n=>[n,process.env[n]]));try{names.forEach(n=>delete process.env[n]);Object.assign(process.env,{NODE_ENV:'production'},env);check(configuration());}finally{for(const[name,value]of Object.entries(saved))if(value===undefined)delete process.env[name];else process.env[name]=value;}}
test('no configured credentials returns no live connection',()=>run({},config=>assert.equal(config,null)));
test('public integration aliases and REST URL normalize correctly',()=>run({SUPABASE_URL:'https://example.supabase.co/rest/v1/',SUPABASE_ANON_KEY:jwt('anon')},config=>{assert.equal(config.url,'https://example.supabase.co');assert.ok(config.key)}));
test('publishable key configuration is accepted',()=>run({NEXT_PUBLIC_SUPABASE_URL:'https://example.supabase.co',NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY:'sb_publishable_test_fixture_only'},config=>assert.ok(config)));
test('privileged legacy key is rejected',()=>run({SUPABASE_URL:'https://example.supabase.co',SUPABASE_ANON_KEY:jwt('service_role')},config=>assert.equal(config,null)));
test('secret key is rejected even under public variable name',()=>run({NEXT_PUBLIC_SUPABASE_URL:'https://example.supabase.co',NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY:'sb_secret_test_fixture_only'},config=>assert.equal(config,null)));
test('malformed key and insecure production URL are rejected',()=>{run({SUPABASE_URL:'https://example.supabase.co',SUPABASE_ANON_KEY:'not-a-key'},config=>assert.equal(config,null));run({SUPABASE_URL:'http://example.com',SUPABASE_ANON_KEY:jwt('anon')},config=>assert.equal(config,null));});
