import nodeTest from 'node:test';
const test=(name,fn)=>nodeTest(name,{timeout:5000},fn);
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import {Worker} from 'node:worker_threads';
import {openHTTPFixture,challengeSignature} from './support.mjs';
import {canonicalJSON,sha256,verifySigned} from '../src/receipt.mjs';
import {authorityState} from '../src/authority.mjs';
const request=fields=>({version:1,requestID:randomUUID(),...fields}),registerPath='/v1/devices/watches',recoverPath=registerPath+'/recover';
async function open(t){const h=await openHTTPFixture();t.after(()=>h.close());const phone=await h.login();return {h,phone};}
async function attempt(h,d=h.a.device(),requestID=randomUUID()){
 const c=(await h.raw('/v1/auth/challenges',canonicalJSON(request({deviceID:d.deviceID,devicePublicKey:d.devicePublicKey})))).data;
 const r={version:1,requestID,watchID:d.deviceID,watchPublicKey:d.devicePublicKey,challengeID:c.challengeID};r.deviceProof=challengeSignature(r,c.challenge,d.privateKey);return {d,r,c};
}
function counts(h){return h.f.inspect('SELECT (SELECT count(*) FROM devices) AS devices,(SELECT count(*) FROM sessions) AS sessions,(SELECT value FROM epoch_allocator) AS epoch')[0];}
function closed(h,phone,p,response){assert.equal(response.status,200);assert.equal(response.data.status,'knownAbandoned');assert.equal(response.data.credential,undefined);assert.equal(response.data.sessionClaims,undefined);const r=response.data.receipt;assert.equal(verifySigned(h.f.receiptPublicKey,r),true);assert.equal(r.body.requestID,p.r.requestID);assert.equal(r.body.requestDigest,sha256(canonicalJSON(p.r)));assert.equal(r.body.operation,'registerWatch');assert.equal(r.body.result,'knownAbandoned');assert.equal(r.body.accountID,phone.context.accountID);assert.equal(r.body.activationEpoch,phone.context.activationEpoch);assert.deepEqual(r.body.registration,{watchID:p.d.deviceID,watchPublicKey:p.d.devicePublicKey});return r;}

test('S23-watch-ttl-1: not-sent original404/expired401 stay unknown until explicit signed recovery closes exact intent',async t=>{
 const {h,phone}=await open(t),p=await attempt(h),before=counts(h);h.f.clock.advance(301);
 assert.equal((await h.call(phone,'/v1/requests/'+p.r.requestID,undefined,{method:'GET'})).status,404);assert.equal((await h.call(phone,registerPath,p.r)).status,401);assert.equal(h.f.inspect('SELECT count(*) AS n FROM requests WHERE request_id=\''+p.r.requestID+'\'')[0].n,0);
 const response=await h.call(phone,recoverPath,p.r),r=closed(h,phone,p,response);assert.deepEqual(counts(h),before);assert.equal(h.f.inspect("SELECT consumed FROM challenges WHERE challenge_id='"+p.c.challengeID+"'")[0].consumed,0);
 for(const change of [{requestDigest:'f'.repeat(64)},{accountID:'another-account'},{activationEpoch:r.body.activationEpoch+1},{registration:{...r.body.registration,watchPublicKey:h.a.device().devicePublicKey}},{result:'registered'}])assert.equal(verifySigned(h.f.receiptPublicKey,{...r,body:{...r.body,...change}}),false);
});

test('explicit recovery before TTL durably fences late register and replays original closed bytes across reopen',async t=>{
 const {h,phone}=await open(t),p=await attempt(h),before=counts(h),first=await h.call(phone,recoverPath,p.r);closed(h,phone,p,first);assert.ok((await h.call(phone,registerPath,p.r)).text===first.text,'exact response bytes');await h.restart();assert.ok((await h.call(phone,recoverPath,p.r)).text===first.text,'exact response bytes');assert.ok((await h.call(phone,'/v1/requests/'+p.r.requestID,undefined,{method:'GET'})).text===first.text,'exact response bytes');assert.deepEqual(counts(h),before);
});

test('committed registration dominates recover even after challenge TTL and keeps exact original credential and receipt',async t=>{
 const {h,phone}=await open(t),p=await attempt(h),first=await h.call(phone,registerPath,p.r);assert.equal(first.status,200);const before=counts(h);h.f.clock.advance(301);await h.restart();const recovered=await h.call(phone,recoverPath,p.r);assert.ok(recovered.text===first.text,'exact response bytes');assert.ok((await h.call(phone,registerPath,p.r)).text===first.text,'exact response bytes');assert.equal(recovered.data.receipt.body.result,'registered');assert.deepEqual(counts(h),before);
});

test('registered COMMIT lost response still recovers original signed result and session without abandonment',async t=>{
 const {h,phone}=await open(t),p=await attempt(h);h.f.faults.dropResponseAfterOperation='registerWatch';await assert.rejects(h.call(phone,registerPath,p.r));h.f.faults.dropResponseAfterOperation=undefined;await h.restart();h.f.clock.advance(301);const original=await h.call(phone,'/v1/requests/'+p.r.requestID,undefined,{method:'GET'}),recovered=await h.call(phone,recoverPath,p.r);assert.equal(recovered.status,200);assert.equal(recovered.data.status,undefined);assert.deepEqual(recovered.data.receipt,original.data.receipt);assert.equal(recovered.data.sessionClaims.sessionID,original.data.sessionClaims.sessionID);assert.equal(recovered.data.credential.sessionID,original.data.sessionClaims.sessionID);
});

test('actual SQL recovery failure before COMMIT cannot close attempt or prevent original live registration',async t=>{
 const {h,phone}=await open(t),p=await attempt(h),db=authorityState(h.f.authority).db;db.exec("CREATE TRIGGER fail_watch_close BEFORE INSERT ON requests WHEN NEW.operation='registerWatch' BEGIN SELECT RAISE(ABORT,'controlled closure failure'); END;");
 assert.equal((await h.call(phone,recoverPath,p.r)).status,503);assert.equal(db.prepare('SELECT count(*) AS n FROM requests WHERE request_id=?').get(p.r.requestID).n,0);db.exec('DROP TRIGGER fail_watch_close');assert.equal((await h.call(phone,registerPath,p.r)).status,200);
});

test('closed COMMIT lost response recovers same signed terminal bytes and blocks late registration after reopen',async t=>{
 const {h,phone}=await open(t),p=await attempt(h);h.f.faults.dropResponseAfterOperation='recoverWatch';await assert.rejects(h.call(phone,recoverPath,p.r));h.f.faults.dropResponseAfterOperation=undefined;const db=authorityState(h.f.authority).db,bytes=Buffer.from(db.prepare('SELECT result FROM requests WHERE request_id=?').get(p.r.requestID).result).toString();await h.restart();const result=await h.call(phone,recoverPath,p.r);closed(h,phone,p,result);assert.ok(result.text===bytes,'exact response bytes');assert.ok((await h.call(phone,registerPath,p.r)).text===bytes,'exact response bytes');
});

test('wrong target key challenge Watch signature and unknown fields cannot close the original attempt',async t=>{
 const {h,phone}=await open(t),p=await attempt(h),before=counts(h);
 for(const change of [{watchID:'another-watch'},{watchPublicKey:h.a.device().devicePublicKey},{challengeID:'missing-challenge'},{deviceProof:Buffer.alloc(64).toString('base64url')}])assert.equal((await h.call(phone,recoverPath,{...p.r,...change})).status,401);
 assert.equal((await h.call(phone,recoverPath,{...p.r,activationEpoch:phone.context.activationEpoch})).status,422);assert.deepEqual(counts(h),before);assert.equal((await h.call(phone,registerPath,p.r)).data.receipt.body.result,'registered');
});

test('waiting Watch foreign-account and invalid Phone PoP callers cannot close or read another original',async t=>{
 const {h,phone}=await open(t),p=await attempt(h),registered=await h.call(phone,registerPath,p.r),watch={d:p.d,credential:registered.data.credential},waiting=await h.login(),foreign=await h.login(undefined,{subject:'other-watch-recovery-account'});
 for(const caller of [waiting,watch])assert.equal((await h.call(caller,recoverPath,p.r)).status,403);assert.equal((await h.call(foreign,recoverPath,p.r)).status,401);assert.equal((await h.call(phone,recoverPath,p.r,{mutateProof:v=>({...v,nonce:randomUUID()})})).status,401);assert.ok((await h.call(phone,recoverPath,p.r)).text===registered.text,'exact response bytes');
});

test('closed original ID is permanently bound to operation and full digest within its current account',async t=>{
 const {h,phone}=await open(t),p=await attempt(h),first=await h.call(phone,recoverPath,p.r);closed(h,phone,p,first);const other=await attempt(h,h.a.device(),p.r.requestID);assert.equal((await h.call(phone,recoverPath,other.r)).status,409);assert.equal((await h.call(phone,registerPath,other.r)).status,409);
 const acquire=request({matchID:'reuse-closed-id',recordingDeviceID:phone.d.deviceID,activationEpoch:phone.context.activationEpoch});acquire.requestID=p.r.requestID;assert.equal((await h.call(phone,'/v1/locks/acquire',acquire)).status,409);assert.ok((await h.call(phone,recoverPath,p.r)).text===first.text,'exact response bytes');
});

for(const first of ['registerWatch','recoverWatch'])test(first+' wins HTTP serial race and the other returns that same original outcome',async t=>{
 const {h,phone}=await open(t),p=await attempt(h),paths={registerWatch:registerPath,recoverWatch:recoverPath},before=counts(h),one=await h.call(phone,paths[first],p.r),two=await h.call(phone,paths[first==='registerWatch'?'recoverWatch':'registerWatch'],p.r);assert.equal(one.status,200);assert.ok(two.text===one.text,'exact response bytes');assert.equal(counts(h).sessions,before.sessions+(first==='registerWatch'?1:0));
});

test('two independent SQLite workers race recover vs register into exactly one original result',async t=>{
 const {h,phone}=await open(t),p=await attempt(h),before=counts(h),barrier=new SharedArrayBuffer(4),view=new Int32Array(barrier),c=h.f.config;
 const workers=['registerWatch','recoverWatch'].map(mode=>new Worker(new URL('./support/watch-registration-recovery-worker.mjs',import.meta.url),{workerData:{mode,barrier,request:p.r,context:phone.context,now:h.f.clock.now(),config:{databasePath:c.databasePath,accountHMACKey:c.accountHMACKey,tokenDerivationKey:c.tokenDerivationKey,receiptPrivateKey:c.receiptPrivateKey.export({type:'pkcs8',format:'pem'}),environment:c.environment,receiptKeyID:c.receiptKeyID}}}));t.after(()=>Promise.all(workers.map(w=>w.terminate())));let ready=0;const outputs=await Promise.all(workers.map(w=>new Promise((resolve,reject)=>{w.on('error',reject);w.on('message',m=>{if(m.ready){if(++ready===2){Atomics.store(view,0,1);Atomics.notify(view,0);}}else resolve(m);});})));
 assert.notEqual(outputs[0].threadId,outputs[1].threadId);for(const o of outputs)assert.equal(o.error,undefined);assert.ok(outputs[0].bytes===outputs[1].bytes,'exact worker result bytes');assert.equal(counts(h).sessions,before.sessions+(outputs[0].result.status==='knownAbandoned'?0:1));assert.ok((await h.call(phone,recoverPath,p.r)).text===outputs[0].bytes,'exact response bytes');
});

test('account deletion removes current closure normally; old session epoch and expired old intent cannot revive on re-registration',async t=>{
 const {h,phone}=await open(t),p=await attempt(h);h.f.clock.advance(301);const proof=await h.call(phone,recoverPath,p.r);closed(h,phone,p,proof);const fresh=await h.login(phone.d),cap=randomBytes(32).toString('base64url');h.f.config.appleRevoker=async()=>({revoked:true});
 const deleted=await h.call(phone,'/v1/accounts/delete',request({reauthenticationID:fresh.result.reauthenticationID,recoveryCapabilityDigest:sha256(cap)}));assert.equal(deleted.status,200);assert.equal((await h.call(phone,recoverPath,p.r)).status,401);const next=await h.login(phone.d);assert.ok(next.context.activationEpoch>phone.context.activationEpoch);assert.equal((await h.call(next,registerPath,p.r)).status,401);const newAttempt=await attempt(h,p.d);assert.equal((await h.call(next,registerPath,newAttempt.r)).data.receipt.body.result,'registered');
});

test('additive recovery uses existing result schema and leaves original signed fixture bytes untouched',async t=>{
 const {h,phone}=await open(t),p=await attempt(h),db=authorityState(h.f.authority).db,before=db.prepare("SELECT sql FROM sqlite_master WHERE type='table' ORDER BY name").all();const result=await h.call(phone,recoverPath,p.r);closed(h,phone,p,result);assert.equal(db.prepare('PRAGMA user_version').get().user_version,2);assert.deepEqual(db.prepare("SELECT sql FROM sqlite_master WHERE type='table' ORDER BY name").all(),before);assert.equal(db.prepare('SELECT consumed FROM challenges WHERE challenge_id=?').get(p.c.challengeID).consumed,0);
});

test('closing a live attempt survives same-anonymous-account deletion without consuming a foreign account challenge',async t=>{
 const {h,phone}=await open(t),p=await attempt(h),first=await h.call(phone,recoverPath,p.r);closed(h,phone,p,first);assert.equal(h.f.inspect("SELECT consumed FROM challenges WHERE challenge_id='"+p.c.challengeID+"'")[0].consumed,0);
 const fenceRows=h.f.inspect('SELECT * FROM auth_absence_fences');assert.equal(fenceRows.length,1);assert.deepEqual(Object.keys(fenceRows[0]),['fence_id']);assert.match(fenceRows[0].fence_id,/^[a-f0-9]{64}$/);
 const fresh=await h.login(phone.d),cap=randomBytes(32).toString('base64url');h.f.config.appleRevoker=async()=>({revoked:true});assert.equal((await h.call(phone,'/v1/accounts/delete',request({reauthenticationID:fresh.result.reauthenticationID,recoveryCapabilityDigest:sha256(cap)}))).status,200);await h.restart();assert.deepEqual(h.f.inspect('SELECT * FROM auth_absence_fences'),fenceRows);assert.equal(h.f.inspect("SELECT count(*) AS n FROM requests WHERE request_id='"+p.r.requestID+"'")[0].n,0);const next=await h.login(phone.d);assert.ok(next.context.activationEpoch>phone.context.activationEpoch);const before=counts(h);
 assert.equal((await h.call(next,registerPath,p.r)).status,401);assert.equal((await h.call(next,recoverPath,p.r)).status,401);assert.deepEqual(counts(h),before);assert.deepEqual(h.f.inspect('SELECT * FROM auth_absence_fences'),fenceRows);const newAttempt=await attempt(h,p.d);assert.equal((await h.call(next,registerPath,newAttempt.r)).data.receipt.body.result,'registered');
});

test('another account closure is scoped and cannot consume the original Watch challenge or block original account commit',async t=>{
 const {h,phone}=await open(t),p=await attempt(h),foreign=await h.login(undefined,{subject:'other-account-own-closure'}),proof=await h.call(foreign,recoverPath,p.r);closed(h,foreign,p,proof);assert.equal(h.f.inspect("SELECT consumed FROM challenges WHERE challenge_id='"+p.c.challengeID+"'")[0].consumed,0);const original=await h.call(phone,registerPath,p.r);assert.equal(original.status,200);assert.equal(original.data.receipt.body.result,'registered');assert.equal(original.data.receipt.body.accountID,phone.context.accountID);
});
