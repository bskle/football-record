import nodeTest from 'node:test';
const test=(name,fn)=>nodeTest(name,{timeout:5000},fn);
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import {readFileSync,existsSync} from 'node:fs';
import {Worker} from 'node:worker_threads';
import {DatabaseSync} from 'node:sqlite';
import {openHTTPFixture,challengeSignature,appleJWT,appleJWKS,tempDB} from './support.mjs';
import {canonicalJSON,sha256} from '../src/receipt.mjs';
import {signRecover,createDeviceAuth} from '../src/device-auth.mjs';
import {createAuthority,authorityState} from '../src/authority.mjs';
import {createHTTPServer} from '../src/http.mjs';
const req=fields=>({version:1,requestID:randomUUID(),...fields}),recoverPath='/v1/auth/recover';
async function open(t){const h=await openHTTPFixture();h.extraServers=[];t.after(async()=>{for(const s of h.extraServers){s.closeAllConnections();await new Promise(resolve=>s.close(resolve));}await h.close();});return h;}
async function prepare(h,d=h.a.device()){
 const challenge=(await h.raw('/v1/auth/challenges',canonicalJSON(req({deviceID:d.deviceID,devicePublicKey:d.devicePublicKey})))).data;
 const r=req({challengeID:challenge.challengeID,identityToken:appleJWT({iss:'https://appleid.apple.com',sub:'auth-absence-subject-SENTINEL',aud:'test.football',nonce:sha256(challenge.challenge),iat:h.f.clock.now(),exp:h.f.clock.now()+300}),authorizationCode:'auth-absence-code-'+randomUUID(),deviceID:d.deviceID,devicePublicKey:d.devicePublicKey,cloudSpaceID:'fixture-cloud'});r.deviceProof=challengeSignature(r,challenge.challenge,d.privateKey);return {r,d};
}
function recovery(h,p,{legacy=false,body={}}={}){const r=req({authRequestID:p.r.requestID,deviceID:p.d.deviceID,keyID:p.d.keyID,nonce:randomUUID(),issuedAt:h.f.clock.now(),...(!legacy?{devicePublicKey:p.d.devicePublicKey}:{}),...body});r.deviceProof=signRecover(p.d.privateKey,r);return r;}
const send=(h,r)=>h.raw(recoverPath,canonicalJSON(r));
const authenticate=(h,p)=>h.raw('/v1/auth/apple',canonicalJSON(p.r));
function snapshot(h){const db=authorityState(h.f.authority).db;return {accounts:db.prepare('SELECT count(*) AS n FROM accounts').get().n,sessions:db.prepare('SELECT count(*) AS n FROM sessions').get().n,devices:db.prepare('SELECT count(*) AS n FROM devices').get().n,epoch:db.prepare('SELECT value FROM epoch_allocator').get().value};}
async function gated(h){let entered,release;const started=new Promise(resolve=>entered=resolve),gate=new Promise(resolve=>release=resolve);const auth=createDeviceAuth({authority:h.f.authority,appleVerifier:{environment:'development',verify:async(...args)=>{const value=await h.a.verifier.verify(...args);entered();await gate;return value;}}});const server=createHTTPServer({authority:h.f.authority,appleVerifier:h.a.verifier,deviceAuth:auth});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));h.extraServers.push(server);return {started,release,async authenticate(p){const response=await fetch('http://127.0.0.1:'+server.address().port+'/v1/auth/apple',{method:'POST',headers:{'content-type':'application/json'},body:canonicalJSON(p.r)});return {status:response.status,data:await response.json()};}};}

for(const failure of ['notSent','beforeCommit'])test('first auth '+failure+' can be abandoned permanently before explicit new-ID login',async t=>{
 const h=await open(t),p=await prepare(h),before=snapshot(h);
 if(failure==='beforeCommit'){h.f.faults.beforeCommit=true;assert.equal((await authenticate(h,p)).status,503);h.f.faults.beforeCommit=false;}
 const result=await send(h,recovery(h,p));assert.equal(result.status,200);assert.deepEqual(result.data,{status:'knownAbandoned'});assert.deepEqual(snapshot(h),before);
 await h.restart();assert.deepEqual((await send(h,recovery(h,p))).data,{status:'knownAbandoned'});assert.equal((await authenticate(h,p)).status,401);assert.deepEqual(snapshot(h),before);
 const fresh=await prepare(h,p.d);assert.notEqual(fresh.r.requestID,p.r.requestID);const login=await authenticate(h,fresh);assert.equal(login.status,200);assert.equal(login.data.receipt.body.result,'registered');assert.equal(snapshot(h).epoch,before.epoch+1);
});

test('auth COMMIT lost response always recovers original session with both new and legacy wire',async t=>{
 const h=await open(t),p=await prepare(h);h.f.faults.dropResponseAfterOperation='authenticate';await assert.rejects(authenticate(h,p));h.f.faults.dropResponseAfterOperation=undefined;const db=authorityState(h.f.authority).db,row=db.prepare('SELECT * FROM auth_records WHERE auth_request_id=?').get(p.r.requestID),session=db.prepare('SELECT * FROM sessions WHERE session_id=?').get(row.session_id);await h.restart();
 for(const legacy of [false,true]){const result=await send(h,recovery(h,p,{legacy}));assert.equal(result.status,200);assert.equal(result.data.credential.sessionID,row.session_id);assert.equal(sha256(result.data.credential.token),session.token_hash);assert.equal(result.data.status,undefined);assert.deepEqual(result.data.receipt,JSON.parse(Buffer.from(row.public_result)).receipt);}
 assert.equal(h.f.inspect('SELECT count(*) AS n FROM auth_absence_fences')[0].n,0);
});

for(const fault of ['beforeCommit','afterCommitLost'])test('recover '+fault+' preserves atomic fence and nonce across reopen',async t=>{
 const h=await open(t),p=await prepare(h),r=recovery(h,p);
 if(fault==='beforeCommit'){h.f.faults.beforeCommit=true;assert.equal((await send(h,r)).status,503);h.f.faults.beforeCommit=false;assert.equal(h.f.inspect('SELECT count(*) AS n FROM auth_absence_fences')[0].n,0);assert.equal((await authenticate(h,p)).status,200);}
 else {h.f.faults.dropResponseAfterOperation='recover';await assert.rejects(send(h,r));h.f.faults.dropResponseAfterOperation=undefined;await h.restart();assert.equal((await send(h,r)).status,401);assert.deepEqual((await send(h,recovery(h,p))).data,{status:'knownAbandoned'});assert.equal((await authenticate(h,p)).status,401);}
});

test('absence proof nonce is durable and changing nonce or issuedAt without resigning is rejected',async t=>{
 const h=await open(t),p=await prepare(h),r=recovery(h,p);assert.deepEqual((await send(h,r)).data,{status:'knownAbandoned'});await h.restart();assert.equal((await send(h,r)).status,401);
 for(const change of [{nonce:randomUUID()},{issuedAt:r.issuedAt-1},{deviceID:'wrong-device'},{keyID:'wrong-key'}])assert.equal((await send(h,{...r,...change})).status,401);
 const sameNonce=recovery(h,p,{body:{nonce:r.nonce}});assert.equal((await send(h,sameNonce)).status,401);assert.deepEqual((await send(h,recovery(h,p))).data,{status:'knownAbandoned'});
});

test('other device or key tuple cannot cancel genuine original auth or read its session',async t=>{
 const h=await open(t),p=await prepare(h),other=h.a.device(p.d.deviceID),otherDevice={...p.d,deviceID:'other-installation'};
 for(const d of [other,otherDevice])assert.deepEqual((await send(h,recovery(h,{r:p.r,d}))).data,{status:'knownAbandoned'});
 const login=await authenticate(h,p);assert.equal(login.status,200);
 assert.equal((await send(h,recovery(h,{r:p.r,d:other}))).status,401);
 const wrongDevice=await send(h,recovery(h,{r:p.r,d:otherDevice}));assert.equal(wrongDevice.data.status,'knownAbandoned');assert.equal(wrongDevice.data.credential,undefined);
 assert.equal((await send(h,recovery(h,p))).data.credential.sessionID,login.data.credential.sessionID);
});

for(const winner of ['recover','authenticate'])test('actual HTTP Apple-await race '+winner+' wins without false absence or late commit',async t=>{
 const h=await open(t),p=await prepare(h),before=snapshot(h),g=await gated(h),pending=g.authenticate(p);await Promise.race([g.started,pending.then(()=>{throw Error('auth never reached verified await barrier');})]);
 if(winner==='recover'){const result=await send(h,recovery(h,p));g.release();const authenticated=await pending;assert.deepEqual(result.data,{status:'knownAbandoned'});assert.equal(authenticated.status,401);assert.deepEqual(snapshot(h),before);}
 else {g.release();const login=await pending;assert.equal(login.status,200);const result=await send(h,recovery(h,p));assert.equal(result.data.credential.sessionID,login.data.credential.sessionID);assert.equal(result.data.status,undefined);}
});

test('independent database workers race one original auth against its abandonment fence',async t=>{
 const h=await open(t),p=await prepare(h),before=snapshot(h),r=recovery(h,p),barrier=new SharedArrayBuffer(4),view=new Int32Array(barrier),config=h.f.config;
 const workers=['authenticate','recover'].map(mode=>new Worker(new URL('./auth-recovery-worker.mjs',import.meta.url),{workerData:{mode,barrier,now:h.f.clock.now(),jwks:appleJWKS,request:mode==='authenticate'?p.r:r,config:{databasePath:config.databasePath,environment:config.environment,accountHMACKey:config.accountHMACKey,tokenDerivationKey:config.tokenDerivationKey,receiptPrivateKey:config.receiptPrivateKey.export({type:'pkcs8',format:'pem'}),receiptKeyID:config.receiptKeyID}}}));
 t.after(()=>Promise.all(workers.map(w=>w.terminate())));let ready=0;const outputs=await Promise.all(workers.map(w=>new Promise((resolve,reject)=>{w.on('error',reject);w.on('message',m=>{if(m.ready){ready++;if(ready===2){Atomics.store(view,0,1);Atomics.notify(view,0);}}else resolve(m);});})));
 assert.notEqual(outputs[0].threadId,outputs[1].threadId);const [auth,recovered]=outputs;
 if(recovered.result?.status==='knownAbandoned'){assert.equal(auth.error.code,'unauthorized');assert.deepEqual(snapshot(h),before);}
 else {assert.ok(auth.result?.credential);assert.equal(recovered.result.credential.sessionID,auth.result.credential.sessionID);assert.equal(snapshot(h).sessions,before.sessions+1);}
});

test('schema1 upgrade is atomic on failure and preserves original result bytes and recovery wire',async t=>{
 const h=await open(t),p=await prepare(h),login=await authenticate(h,p);assert.equal(login.status,200);const source=authorityState(h.f.authority).db,row=source.prepare('SELECT * FROM auth_records WHERE auth_request_id=?').get(p.r.requestID),copy=tempDB();source.exec("VACUUM INTO '"+copy+"'");
 const db=new DatabaseSync(copy);db.exec("DROP TABLE IF EXISTS auth_recovery_nonces; DROP TABLE IF EXISTS auth_absence_fences; PRAGMA user_version=1; CREATE TRIGGER fail_migration BEFORE INSERT ON metadata BEGIN SELECT RAISE(ABORT,'controlled migration failure'); END;");db.close();
 const config={...h.f.config,databasePath:copy};assert.throws(()=>createAuthority(config),/controlled migration failure/);const failed=new DatabaseSync(copy);assert.equal(failed.prepare('PRAGMA user_version').get().user_version,1);assert.equal(failed.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name='auth_absence_fences'").get().n,0);assert.deepEqual(Buffer.from(failed.prepare('SELECT public_result FROM auth_records WHERE auth_request_id=?').get(p.r.requestID).public_result),Buffer.from(row.public_result));failed.exec('DROP TRIGGER fail_migration');failed.close();
 const authority=createAuthority(config);t.after(()=>authority.close());const state=authorityState(authority);assert.equal(state.db.prepare('PRAGMA user_version').get().user_version,2);const auth=createDeviceAuth({authority,appleVerifier:h.a.verifier}),recovered=auth.recover(recovery(h,p,{legacy:true}));assert.equal(recovered.credential.sessionID,login.data.credential.sessionID);assert.deepEqual(Buffer.from(state.db.prepare('SELECT public_result FROM auth_records WHERE auth_request_id=?').get(p.r.requestID).public_result),Buffer.from(row.public_result));
});

test('after deletion knownAbandoned means present absence plus fence and retains no raw identity in new rows or DB logs',async t=>{
 const h=await open(t),p=await prepare(h),login=await authenticate(h,p),again=await prepare(h,p.d),fresh=await authenticate(h,again);h.f.config.appleRevoker=async()=>({revoked:true});const caller={d:p.d,credential:login.data.credential},cap=randomBytes(32).toString('base64url');
 const deleted=await h.call(caller,'/v1/accounts/delete',req({reauthenticationID:fresh.data.reauthenticationID,recoveryCapabilityDigest:sha256(cap)}));assert.equal(deleted.status,200);const before=snapshot(h);assert.deepEqual((await send(h,recovery(h,p))).data,{status:'knownAbandoned'});assert.deepEqual(snapshot(h),before);
 const rows=h.f.inspect('SELECT * FROM auth_absence_fences'),nonceRows=h.f.inspect('SELECT * FROM auth_recovery_nonces');assert.deepEqual(Object.keys(rows[0]),['fence_id']);assert.match(rows[0].fence_id,/^[a-f0-9]{64}$/);assert.deepEqual(Object.keys(nonceRows[0]).sort(),['fence_id','nonce_hash']);
 const needles=[p.r.identityToken,p.r.authorizationCode,again.r.identityToken,again.r.authorizationCode,'auth-absence-subject-SENTINEL',login.data.credential.token,fresh.data.credential.token];const chunks=[Buffer.from(JSON.stringify(h.logs)),Buffer.from(JSON.stringify(rows)),Buffer.from(JSON.stringify(nonceRows))];for(const file of [h.f.config.databasePath,h.f.config.databasePath+'-wal',h.f.config.databasePath+'-shm'])if(existsSync(file))chunks.push(readFileSync(file));for(const bytes of chunks)for(const needle of needles)assert.equal(bytes.includes(Buffer.from(needle)),false);for(const value of [p.r.requestID,p.d.deviceID,p.d.keyID,p.d.devicePublicKey])assert.equal(JSON.stringify(rows).includes(value),false);
});

test('old missing-row wire stays unauthorized and existing revoked or expired sessions never become absence',async t=>{
 const h=await open(t),missing=await prepare(h);assert.equal((await send(h,recovery(h,missing,{legacy:true}))).status,401);const p=await prepare(h),login=await authenticate(h,p);assert.equal(login.status,200);const db=authorityState(h.f.authority).db;
 db.prepare('UPDATE sessions SET expires_at=? WHERE session_id=?').run(h.f.clock.now()-1,login.data.credential.sessionID);assert.deepEqual((await send(h,recovery(h,p))).data,{status:'knownExpired'});db.prepare('UPDATE sessions SET revoked=1 WHERE session_id=?').run(login.data.credential.sessionID);assert.deepEqual((await send(h,recovery(h,p,{legacy:true}))).data,{status:'knownRevoked'});db.prepare('DELETE FROM sessions WHERE session_id=?').run(login.data.credential.sessionID);const missingSession=recovery(h,p);assert.deepEqual((await send(h,missingSession)).data,{status:'knownRevoked'});assert.equal((await send(h,missingSession)).status,401);assert.equal(h.f.inspect('SELECT count(*) AS n FROM auth_absence_fences')[0].n,0);
});

test('strict absence recovery rejects wrong fingerprint key signature time nonce and unknown fields before fence',async t=>{
 const h=await open(t),p=await prepare(h),valid=recovery(h,p),wrong=h.a.device();
 for(const body of [{...valid,keyID:wrong.keyID},{...valid,devicePublicKey:wrong.devicePublicKey},{...valid,deviceProof:Buffer.alloc(64).toString('base64url')},recovery(h,p,{body:{issuedAt:h.f.clock.now()-61}})])assert.equal((await send(h,body)).status,401);
 for(const body of [{...valid,devicePublicKey:'bad'},{...valid,nonce:'bad nonce'},{...valid,issuedAt:1.5},{...valid,accountID:'self-report'},{...valid,devicePublicKey:{raw:p.d.devicePublicKey}}])assert.equal((await h.raw(recoverPath,JSON.stringify(body))).status,422);
 assert.equal(h.f.inspect('SELECT count(*) AS n FROM auth_absence_fences')[0].n,0);assert.equal((await authenticate(h,p)).status,200);const wrongKnown=recovery(h,p,{body:{devicePublicKey:wrong.devicePublicKey,keyID:wrong.keyID}});assert.equal((await send(h,wrongKnown)).status,401);
});
