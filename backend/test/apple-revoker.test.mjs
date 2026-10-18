import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync,verify} from 'node:crypto';
import {startRevocationFixture} from './apple-revocation-support.mjs';
import {decodeBase64URL} from '../src/receipt.mjs';

test('real loopback exchange/revoke uses exact forms, genuine ES256 raw64 JWT and empty 200 success',async t=>{
 const f=await startRevocationFixture();t.after(()=>f.close());assert.deepEqual(await f.revoker(await f.input()),{revoked:true});
 const token=f.requests.find(r=>r.path==='/auth/token'),revoke=f.requests.find(r=>r.path==='/auth/revoke');assert.equal(token.validSecret,true);assert.equal(revoke.validSecret,true);
 assert.equal(token.contentType,'application/x-www-form-urlencoded');assert.equal(Object.keys(token.fields).sort().join(','),'client_id,client_secret,code,grant_type');assert.equal(token.fields.grant_type,'authorization_code');assert.equal(Object.keys(revoke.fields).sort().join(','),'client_id,client_secret,token,token_type_hint');assert.equal(revoke.fields.token_type_hint,'refresh_token');
 const [h,p,s]=token.fields.client_secret.split('.');assert.equal(decodeBase64URL(s).length,64);assert.equal(verify('sha256',Buffer.from(h+'.'+p),{key:f.config.privateKey,dsaEncoding:'der'},decodeBase64URL(s)),false);
});
for(const [name,controls]of Object.entries({issuer:{claims:{iss:'https://evil.invalid'}},subject:{claims:{sub:'other-subject'}},audience:{claims:{aud:'other-client'}},nonce:{claims:{nonce:'other-nonce'}},expiry:{claims:{exp:1}},future:{claims:{iat:1900000000}},kid:{header:{alg:'RS256',kid:'unknown'}},signature:{badSignature:true},algorithm:{header:{alg:'none',kid:'revocation-rsa'}},missingID:{response:{id_token:null}},missingRefresh:{response:{refresh_token:null}},accessOnly:{response:{refresh_token:undefined}},nonJSONWhitespace:{exchangePrefix:'\u00a0'},duplicate:{exchangeRaw:'{"id_token":"a","id_token":"b","refresh_token":"c"}'},oversized:{exchangeRaw:'x'.repeat(32769)},nested:{response:{refresh_token:{raw:'secret'}}}}))test('exchange '+name+' cannot reach revoke or leak a response',async t=>{
 const f=await startRevocationFixture();t.after(()=>f.close());const input=await f.input();Object.assign(f.controls,controls);await assert.rejects(f.revoker(input),e=>e.code==='reauthenticationRequired'&&e.message==='reauthenticationRequired');assert.equal(f.requests.filter(r=>r.path==='/auth/revoke').length,0);
});
for(const phase of ['exchange','revoke'])for(const fault of ['Status','Timeout','Disconnect'])test(phase+' '+fault+' returns bounded error without automatically retrying code',async t=>{
 const f=await startRevocationFixture({timeoutMs:40});t.after(()=>f.close());const input=await f.input();f.controls[phase+fault]=fault==='Status'?503:true;
 await assert.rejects(f.revoker(input),e=>e.code==='reauthenticationRequired'&&!JSON.stringify(e).includes('SENTINEL'));await assert.rejects(f.revoker(input),e=>e.code==='reauthenticationRequired');assert.equal(f.requests.filter(r=>r.path==='/auth/token').length,1);
});
test('redirect is never followed; original configured verified redirect is exact or absent',async t=>{
 const f=await startRevocationFixture();t.after(()=>f.close());const input=await f.input();f.controls.exchangeRedirect=true;await assert.rejects(f.revoker(input),e=>e.code==='reauthenticationRequired');assert.notEqual(f.controls.redirectReached,true);
 const uri='https://app.example/auth/callback',g=await startRevocationFixture({redirectURIs:{'test.football':uri}});t.after(()=>g.close());const withRedirect=await g.input({flow:{authorizationRedirectURI:uri}});await g.revoker(withRedirect);assert.equal(g.requests.find(r=>r.path==='/auth/token').fields.redirect_uri,uri);
});
test('factory/environment/verified-context boundaries reject development or untyped input in production',async t=>{
 const f=await startRevocationFixture();t.after(()=>f.close());const {createAppleRevoker,createDevelopmentAppleRevoker}=await import('../src/apple-revoker.mjs'),{createAppleVerifier}=await import('../src/apple-verifier.mjs'),{createAuthority}=await import('../src/authority.mjs'),{startFixtureAuthority,tempDB}=await import('./support.mjs');
 const {baseURL,timeoutMs,...productionConfig}=f.config;assert.throws(()=>createAppleRevoker(productionConfig));
 const verifier=createAppleVerifier({audiences:['test.football'],clock:f.clock});
 assert.throws(()=>createAppleRevoker({...f.config,appleVerifier:verifier,baseURL:undefined,fetch:()=>{}}));
 for(const baseURL of ['http://localhost:1','http://127.0.0.1.evil:1','https://evil.example','http://127.0.0.1:1/path'])assert.throws(()=>createDevelopmentAppleRevoker({...f.config,baseURL}));
 const input=await f.input();await assert.rejects(f.revoker({...input,expectedApple:{...input.expectedApple}}),e=>e.code==='reauthenticationRequired');
 const a=await startFixtureAuthority();t.after(()=>a.close());assert.throws(()=>createAuthority({...a.config,databasePath:tempDB(),environment:'production',appleRevoker:f.revoker}));assert.throws(()=>createAuthority({...a.config,databasePath:tempDB(),environment:'production',appleRevoker:async()=>({revoked:true})}));
 assert.equal(Object.isFrozen(f.revoker),true);assert.equal(f.revoker.environment,'development');
});
test('P256 private key is required and client secret stays exactly short-lived JOSE',async t=>{
 const f=await startRevocationFixture();t.after(()=>f.close());const {createAppleClientSecret}=await import('../src/apple-client-secret.mjs');
 const jwt=createAppleClientSecret({teamID:f.config.teamID,keyID:f.config.keyID,clientID:'test.football',privateKey:f.config.privateKey,clock:f.clock});assert.equal(f.validSecret(jwt),true);
 const wrong=generateKeyPairSync('ec',{namedCurve:'secp384r1'});assert.throws(()=>createAppleClientSecret({...f.config,clientID:'test.football',privateKey:wrong.privateKey}));
});

test('production factory accepts genuine production verifier but refuses development verified identity before outbound transport',async t=>{
 const f=await startRevocationFixture();t.after(()=>f.close());const input=await f.input();const {createAppleRevoker}=await import('../src/apple-revoker.mjs'),{createAppleVerifier,isAppleVerifier}=await import('../src/apple-verifier.mjs');
 const originalFetch=globalThis.fetch,calls=[];
 try {
  globalThis.fetch=async(url,options)=>{calls.push({url:String(url),redirect:options?.redirect});throw Error('intercepted; no real outbound network');};
  const verifier=createAppleVerifier({audiences:['test.football'],clock:f.clock});
  const {baseURL,timeoutMs,...config}=f.config;const revoker=createAppleRevoker({...config,appleVerifier:verifier});
  await assert.rejects(revoker(input),e=>e.code==='reauthenticationRequired');assert.equal(calls.length,0);assert.equal(isAppleVerifier(verifier,'production'),true);assert.equal(revoker.environment,'production');
 }finally{globalThis.fetch=originalFetch;}
});
