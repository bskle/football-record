import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {startFixtureAuthority,tempDB,authSetup,appleJWKS,challengeSignature} from './support.mjs';
import {canonicalJSON,decodeBase64URL,sha256,verifySigned} from '../src/receipt.mjs';

for(const [name,overrides] of Object.entries({issuer:{claims:{iss:'https://evil.invalid'}},audience:{claims:{aud:'wrong'}},nonce:{claims:{nonce:'wrong'}},expired:{claims:{exp:1}},future:{claims:{iat:1900000000}},kid:{header:{alg:'RS256',kid:'unknown'}},alg:{header:{alg:'none',kid:'fixture-apple'}}})){
  test('Apple JWT rejects '+name,async t=>{const f=await startFixtureAuthority();t.after(()=>f.close());const a=await authSetup(f);await assert.rejects(a.login(a.device(),overrides),e=>e.code==='unauthorized');});
}
for(const [name,value] of [['kty','EC'],['alg','RS512'],['use','enc']])test('JWKS rejects wrong '+name,async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const a=await authSetup(f,{fetchJWKS:async()=>({keys:[{...appleJWKS.keys[0],[name]:value}]})});await assert.rejects(a.login(),e=>e.code==='unauthorized');
});
test('signature failure, replayed challenge, UUID key rotation and second phone activation are rejected or waiting',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const a=await authSetup(f),d=a.device();
 const bad=a.request(d);bad.r.identityToken=bad.r.identityToken.slice(0,-5)+'AAAAA';bad.r.deviceProof=challengeSignature(bad.r,bad.challenge.challenge,d.privateKey);
 await assert.rejects(a.auth.authenticate(bad.r),e=>e.code==='unauthorized');
 const first=await a.login(d);await assert.rejects(a.auth.authenticate(first.r),e=>e.code==='unauthorized');
 await assert.rejects(a.login(a.device(d.deviceID)),e=>e.code==='unauthorized');
 const second=await a.login();assert.equal(second.result.receipt.body.result,'waitingMigration');
 assert.equal(first.credential.activationEpoch,second.credential.activationEpoch);
 assert.throws(()=>f.authority.acquire(second.context,{...f.acquire('waiting'),recordingDeviceID:second.d.deviceID,activationEpoch:second.credential.activationEpoch}),e=>e.code==='activationMismatch');
});
test('auth commit response lost recovers original credential using fresh bound device proof after reopen',async t=>{
 const f=await startFixtureAuthority({databasePath:tempDB()});t.after(()=>f.close());let a=await authSetup(f);const d=a.device(),{r}=a.request(d);
 f.faults.afterCommitResponseLost=true;await assert.rejects(a.auth.authenticate(r),e=>e.code==='responseLost');f.faults.afterCommitResponseLost=false;
 const before=f.inspect('SELECT token_hash,session_id FROM sessions')[0];
 await f.restart();a=await authSetup(f);
 const req={version:1,requestID:randomUUID(),authRequestID:r.requestID,deviceID:d.deviceID,keyID:d.keyID,nonce:randomUUID(),issuedAt:f.clock.now()};
 const {signRecover}=await import('../src/device-auth.mjs');req.deviceProof=signRecover(d.privateKey,req);
 const recovered=a.auth.recover(req);assert.equal(recovered.credential.sessionID,before.session_id);assert.equal(sha256(recovered.credential.token),before.token_hash);
 assert.throws(()=>a.auth.recover(req),e=>e.code==='unauthorized');
 const raw=readFileSync(f.config.databasePath);assert.equal(raw.includes(Buffer.from(r.identityToken)),false);assert.equal(raw.includes(Buffer.from('fixture-subject-never-stored')),false);assert.equal(raw.includes(Buffer.from(recovered.credential.token)),false);
});
test('device PoP covers method path digest session epoch nonce and issuedAt before durable nonce use',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const a=await authSetup(f),login=await a.login();
 const input={authorization:'Bearer '+login.credential.token,method:'POST',path:'/v1/locks/acquire',requestID:'pop-request',bodyBytes:Buffer.from('{}')};
 const p=a.proof(login);
 for(const change of [{nonce:randomUUID()},{issuedAt:f.clock.now()-1}])assert.throws(()=>a.auth.authenticateRequest({...input,proof:{...p,...change}}),e=>e.code==='unauthorized');
 assert.equal(a.auth.authenticateRequest({...input,proof:p}).deviceID,login.d.deviceID);
 assert.throws(()=>a.auth.authenticateRequest({...input,proof:p}),e=>e.code==='unauthorized');
 await f.restart();const a2=await authSetup(f);assert.throws(()=>a2.auth.authenticateRequest({...input,proof:p}),e=>e.code==='unauthorized');
});
test('fresh same-key reauthentication is single use and does not change active epoch',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const a=await authSetup(f),first=await a.login();
 assert.equal(first.result.reauthenticationID,undefined);
 const second=await a.login(first.d);assert.equal(second.credential.activationEpoch,first.credential.activationEpoch);
 assert.ok(second.result.reauthenticationID);
 assert.equal(f.inspect('SELECT consumed FROM reauthentications')[0].consumed,0);
});
test('receipt wire uses fixed domain canonical ASCII body raw 32-byte Ed25519 key and 64-byte signature',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const r=f.authority.acquire(f.context,f.acquire('wire'));
 assert.equal(decodeBase64URL(f.receiptPublicKey).length,32);assert.equal(decodeBase64URL(r.signature).length,64);
 assert.equal(verifySigned(f.receiptPublicKey,r),true);assert.equal(verifySigned(f.receiptPublicKey,r,'other.domain'),false);
 assert.equal(verifySigned(f.receiptPublicKey,{...r,body:{...r.body,matchID:'changed'}}),false);
 const fixture=JSON.parse(readFileSync(new URL('./fixtures/receipt-v1.json',import.meta.url)));
 assert.equal(canonicalJSON(fixture.receipt.body),fixture.canonicalBody);assert.equal(verifySigned(fixture.publicKey,fixture.receipt),true);
});
test('JWKS bounded cache coalesces unknown kid refresh and fails closed on fetch errors',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());let fetches=0;const a=await authSetup(f,{fetchJWKS:async()=>{fetches++;return structuredClone(appleJWKS);}});
 await a.login();assert.equal(fetches,1);
 await Promise.allSettled([a.login(a.device(),{header:{alg:'RS256',kid:'missing'}}),a.login(a.device(),{header:{alg:'RS256',kid:'missing'}})]);assert.equal(fetches,2);
 f.clock.advance(3601);await a.login();assert.equal(fetches,3);
 const broken=await authSetup(f,{fetchJWKS:async()=>{throw Error('secret upstream body');}});await assert.rejects(broken.login(),e=>e.code==='unavailable'&&e.message==='unavailable');
});

test('reauthentication retains Apple issued time and cannot be extended by delayed submission',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const a=await authSetup(f),first=await a.login();
 await a.login(first.d,{claims:{iat:f.clock.now()-20}});
 const row=f.inspect('SELECT issued_at,expires_at FROM reauthentications')[0];assert.equal(row.issued_at,f.clock.now()-20);assert.equal(row.expires_at,row.issued_at+300);
});
test('challenge expiry and swapping a valid JWT onto a new device key fail closed',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const a=await authSetup(f),one=a.request(a.device());f.clock.advance(301);await assert.rejects(a.auth.authenticate(one.r),e=>e.code==='unauthorized');
 const source=a.request(a.device()),other=a.device(),swap=a.request(other);swap.r.identityToken=source.r.identityToken;swap.r.deviceProof=challengeSignature(swap.r,swap.challenge.challenge,other.privateKey);await assert.rejects(a.auth.authenticate(swap.r),e=>e.code==='unauthorized');
});
test('existing database rejects missing or changed explicit keys',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const {createAuthority}=await import('../src/authority.mjs');
 for(const field of ['accountHMACKey','tokenDerivationKey','receiptPrivateKey'])assert.throws(()=>createAuthority({...f.config,[field]:undefined}),/explicit persistent/);
 assert.throws(()=>createAuthority({...f.config,tokenDerivationKey:Buffer.alloc(32,1)}),/configuration mismatch/);
});
test('GET proof binds original request path and empty body and live status uses a separate nonce-bound domain',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const a=await authSetup(f),l=await a.login();
 const fields={method:'GET',path:'/v1/requests/one',requestID:'one',bodyBytes:Buffer.alloc(0)};
 const p=a.proof(l,fields),input={...fields,authorization:'Bearer '+l.credential.token,proof:p};
 assert.throws(()=>a.auth.authenticateRequest({...input,path:'/v1/requests/two',requestID:'two'}),e=>e.code==='unauthorized');
 assert.equal(a.auth.authenticateRequest(input).deviceID,l.d.deviceID);
 const r=f.authority.acquire(f.context,f.acquire('fresh'));
 const status=f.authority.liveStatus(f.context,{version:1,requestID:'status-query',acquireRequestID:r.body.requestID,matchID:r.body.matchID,lockID:r.body.lockID,recordingDeviceID:r.body.recordingDeviceID,activationEpoch:r.body.activationEpoch,nonce:'fresh-nonce'});
 assert.equal(verifySigned(f.receiptPublicKey,status,'football-record.authority.live-lock.v1'),true);assert.equal(verifySigned(f.receiptPublicKey,status),false);
 assert.equal(status.body.nonce,'fresh-nonce');assert.equal(status.body.expiresAt-status.body.observedAt,60);
});

test('challenge lost response reconstructs same secret and expiry; altered intent conflicts and consumed ID is terminal',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());let a=await authSetup(f);const d=a.device(),r={version:1,requestID:'stable-challenge',deviceID:d.deviceID,devicePublicKey:d.devicePublicKey};
 const first=a.auth.challenge(r);f.clock.advance(10);await f.restart();a=await authSetup(f);assert.deepEqual(a.auth.challenge(r),first);
 assert.throws(()=>a.auth.challenge({...r,deviceID:'altered-device'}),e=>e.code==='idempotencyConflict');
 const login=a.request(d);await a.auth.authenticate(login.r);
 const terminal=a.auth.challenge({version:1,requestID:login.challenge.requestID,deviceID:d.deviceID,devicePublicKey:d.devicePublicKey});assert.equal(terminal.status,'consumed');assert.equal(terminal.challenge,undefined);
});
