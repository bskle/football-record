import test from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes,randomUUID} from 'node:crypto';
import {startFixtureAuthority,authSetup,tempDB,challengeSignature} from './support.mjs';
import {sha256} from '../src/receipt.mjs';
const req=fields=>({version:1,requestID:randomUUID(),...fields});
async function phones(f){const a=await authSetup(f),old=await a.login(),waiting=await a.login();return {a,old,waiting};}
function matchRequest(l,id='match-start'){return {version:1,requestID:id,matchID:'match-'+id,recordingDeviceID:l.d.deviceID,activationEpoch:l.credential.activationEpoch};}

test('normal migration rejects waiting preparer and active match, freezes starts and persists final checkpoint CAS',async t=>{
 const f=await startFixtureAuthority({databasePath:tempDB()});t.after(()=>f.close());let {a,old,waiting}=await phones(f);
 const prepare=req({newPhoneID:waiting.d.deviceID,activationEpoch:old.credential.activationEpoch});
 assert.throws(()=>f.authority.prepareMigration(waiting.context,prepare),e=>e.code==='activationMismatch');
 const lock=f.authority.acquire(old.context,matchRequest(old));assert.throws(()=>f.authority.prepareMigration(old.context,prepare),e=>e.code==='migrationBlocked');
 f.authority.terminate(old.context,req({matchID:lock.body.matchID,lockID:lock.body.lockID,recordingDeviceID:old.d.deviceID,activationEpoch:old.credential.activationEpoch,mode:'abnormal'}));
 const started=f.authority.prepareMigration(old.context,prepare),m=started.body.migration;
 assert.throws(()=>f.authority.acquire(old.context,matchRequest(old,'blocked')),e=>e.code==='migrationBlocked');
 const checkpoint=req({migrationID:m.migrationID,checkpointID:'final-checkpoint',contentCommitment:'a'.repeat(64),activationEpoch:old.credential.activationEpoch});
 const saved=f.authority.checkpointMigration(old.context,checkpoint);assert.equal(saved.body.result,'checkpointAccepted');
 await f.restart();a=await authSetup(f);
 const activate=req({migrationID:m.migrationID,checkpointID:'final-checkpoint',contentCommitment:'a'.repeat(64),cloudSpaceID:'fixture-cloud'});
 assert.throws(()=>f.authority.activateMigration(waiting.context,{...activate,contentCommitment:'b'.repeat(64)}),e=>e.code==='migrationBlocked');
 assert.throws(()=>f.authority.activateMigration(waiting.context,{...activate,cloudSpaceID:'different-cloud'}),e=>e.code==='cloudIdentityMismatch');
 const activated=f.authority.activateMigration(waiting.context,activate);assert.equal(activated.body.result,'activated');assert.ok(activated.body.activationEpoch>old.credential.activationEpoch);
 const account=f.inspect("SELECT * FROM accounts WHERE account_id='"+old.context.accountID+"'")[0];assert.equal(account.cloud_space_id,'fixture-cloud');assert.equal(account.active_phone_id,waiting.d.deviceID);
 assert.throws(()=>f.authority.acquire(old.context,matchRequest(old,'old-epoch')),e=>e.code==='activationMismatch');
 const current=await a.login(waiting.d);assert.equal(current.credential.activationEpoch,activated.body.activationEpoch);
 assert.equal(f.authority.acquire(current.context,matchRequest(current,'new-epoch')).body.result,'held');
});
test('lost migration persists original seven-day time across retries, clock rollback and reopen',async t=>{
 const f=await startFixtureAuthority({databasePath:tempDB()});t.after(()=>f.close());let {old,waiting}=await phones(f);
 const request=req({newPhoneID:waiting.d.deviceID,cloudSpaceID:'fixture-cloud'}),first=f.authority.requestLostMigration(waiting.context,request);
 const m=first.body.migration;assert.equal(m.eligibleAt-m.requestedAt,604800);
 f.clock.advance(400);assert.equal(f.authority.requestLostMigration(waiting.context,req({newPhoneID:waiting.d.deviceID,cloudSpaceID:'fixture-cloud'})).body.migration.requestedAt,m.requestedAt);
 f.clock.set(m.requestedAt-100);await f.restart();assert.equal(f.authority.requestLostMigration(waiting.context,request).body.migration.eligibleAt,m.eligibleAt);
 f.clock.set(m.eligibleAt-1);assert.throws(()=>f.authority.forceMigration(waiting.context,req({migrationID:m.migrationID,reauthenticationID:'none'})),e=>e.code==='waitingPeriod');
 f.clock.advance(1);assert.throws(()=>f.authority.forceMigration(waiting.context,req({migrationID:m.migrationID,reauthenticationID:'none'})),e=>e.code==='reauthenticationRequired');
});
test('lost recovery gives only exact old-lock abnormal authority, then fresh reauth forces a globally new epoch',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const {a,old,waiting}=await phones(f);
 const lock=f.authority.acquire(old.context,matchRequest(old));const lost=f.authority.requestLostMigration(waiting.context,req({newPhoneID:waiting.d.deviceID,cloudSpaceID:'fixture-cloud'})).body.migration;
 const early=await a.login(waiting.d);f.clock.set(lost.eligibleAt);
 const fresh=await a.login(waiting.d);
 const fields={migrationID:lost.migrationID,matchID:lock.body.matchID,lockID:lock.body.lockID,originalRecordingDeviceID:lock.body.recordingDeviceID,originalActivationEpoch:lock.body.activationEpoch};
 assert.throws(()=>f.authority.lostRecovery(waiting.context,req({...fields,reauthenticationID:early.result.reauthenticationID,confirmedAt:f.clock.now()})),e=>e.code==='reauthenticationRequired');
 assert.throws(()=>f.authority.forceMigration(waiting.context,req({migrationID:lost.migrationID,reauthenticationID:fresh.result.reauthenticationID})),e=>e.code==='migrationBlocked');
 const grant=f.authority.lostRecovery(waiting.context,req({...fields,reauthenticationID:fresh.result.reauthenticationID,confirmedAt:f.clock.now()}));
 assert.equal(grant.body.result,'grantIssued');assert.throws(()=>f.authority.acquire(waiting.context,matchRequest(waiting,'forbidden')),e=>e.code==='activationMismatch');
 assert.throws(()=>f.authority.terminateLost(waiting.context,req({...fields,grantID:grant.body.lostRecovery.grantID,lockID:'wrong'})),e=>e.code==='lockMismatch');
 const end=f.authority.terminateLost(waiting.context,req({...fields,grantID:grant.body.lostRecovery.grantID}));assert.equal(end.body.result,'releasedAbnormal');assert.equal(end.body.recordingDeviceID,old.d.deviceID);
 assert.throws(()=>f.authority.forceMigration(waiting.context,req({migrationID:lost.migrationID,reauthenticationID:fresh.result.reauthenticationID})),e=>e.code==='reauthenticationRequired');
 const freshAgain=await a.login(waiting.d);const active=f.authority.forceMigration(waiting.context,req({migrationID:lost.migrationID,reauthenticationID:freshAgain.result.reauthenticationID}));assert.ok(active.body.activationEpoch>old.credential.activationEpoch);
});
test('delete saga retains stage on revocation failure then capability recovers commit response lost after credentials removed',async t=>{
 const f=await startFixtureAuthority({databasePath:tempDB()});t.after(()=>f.close());let a=await authSetup(f),l=await a.login();const fresh=await a.login(l.d),capability=randomBytes(32).toString('base64url');
 const request=req({reauthenticationID:fresh.result.reauthenticationID,recoveryCapabilityDigest:sha256(capability)});
 f.config.appleRevoker=async()=>{throw Error('transient secret revocation failure');};
 await assert.rejects(f.authority.deleteAccount(l.context,request),e=>e.code==='reauthenticationRequired');
 assert.equal(f.inspect('SELECT state FROM deletions')[0].state,'lockReconciled');assert.equal(f.inspect('SELECT count(*) AS n FROM sessions')[0].n>0,true);
 await f.restart();a=await authSetup(f);const again=await a.login(l.d);
 // A new reauthentication cannot change the original delete business intent: retry via the bound saga-specific proof.
 f.config.appleRevoker=async()=>({revoked:true});
 f.faults.afterDeleteCommitResponseLost=true;
 await assert.rejects(f.authority.deleteAccount(l.context,request),e=>e.code==='responseLost');f.faults.afterDeleteCommitResponseLost=false;
 assert.equal(f.inspect('SELECT count(*) AS n FROM auth_records')[0].n,0);
 assert.equal(f.inspect('SELECT count(*) AS n FROM sessions')[0].n,0);
 assert.equal(f.inspect('SELECT count(*) AS n FROM qualifications')[0].n,0);
 await f.restart();
 const status=f.authority.deleteStatus(req({deleteRequestID:request.requestID,recoveryCapability:capability}));assert.equal(status.status,'backendDeleted');assert.equal(status.receipt.body.result,'deleted');
 assert.throws(()=>f.authority.deleteStatus(req({deleteRequestID:request.requestID,recoveryCapability:randomBytes(32).toString('base64url')})),e=>e.code==='unauthorized');
 const raw=f.inspect('SELECT * FROM deletion_receipts')[0];assert.equal(JSON.stringify(raw).includes(capability),false);
 const a2=await authSetup(f),reregistered=await a2.login(l.d);assert.ok(reregistered.credential.activationEpoch>l.credential.activationEpoch);
 assert.throws(()=>f.authority.acquire(l.context,matchRequest(l,'stale')),e=>e.code==='activationMismatch');
 f.clock.advance(2592001);assert.equal(f.authority.deleteStatus(req({deleteRequestID:request.requestID,recoveryCapability:capability})).status,'receiptExpired');
});
test('delete cannot skip an active lock or mistake backend outcome for cloud local or health deletion',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const {a,old}=await phones(f),fresh=await a.login(old.d),cap=randomBytes(32).toString('base64url');
 const lock=f.authority.acquire(old.context,matchRequest(old));const r=req({reauthenticationID:fresh.result.reauthenticationID,recoveryCapabilityDigest:sha256(cap)});
 await assert.rejects(f.authority.deleteAccount(old.context,r),e=>e.code==='activeMatchExists');
 assert.equal(f.inspect('SELECT count(*) AS n FROM active_locks')[0].n,1);
 f.authority.terminate(old.context,req({matchID:lock.body.matchID,lockID:lock.body.lockID,recordingDeviceID:old.d.deviceID,activationEpoch:old.credential.activationEpoch,mode:'abnormal'}));
 f.config.appleRevoker=async()=>({revoked:true});const deleted=await f.authority.deleteAccount(old.context,r);
 assert.equal(deleted.body.deletion.backend,'backendDeleted');assert.equal(deleted.body.deletion.cloud,'clientManaged');assert.equal(deleted.body.deletion.health,'separateConfirmation');
});

test('delete revocation stays unavailable by default and another device cannot refresh pending saga authorization',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const {a,old,waiting}=await phones(f),fresh=await a.login(old.d),cap=randomBytes(32).toString('base64url');
 const r=req({reauthenticationID:fresh.result.reauthenticationID,recoveryCapabilityDigest:sha256(cap)});
 await assert.rejects(f.authority.deleteAccount(old.context,r),e=>e.code==='unavailable');
 const before=f.inspect('SELECT reauthentication_id FROM deletions')[0].reauthentication_id;await a.login(waiting.d);
 assert.equal(f.inspect('SELECT reauthentication_id FROM deletions')[0].reauthentication_id,before);
 await assert.rejects(f.authority.deleteAccount(waiting.context,r),e=>e.code==='activationMismatch');
});
test('delete rechecks exact pending proof and epoch after outside-transaction revocation await',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const a=await authSetup(f),l=await a.login(),fresh=await a.login(l.d),cap=randomBytes(32).toString('base64url');
 const r=req({reauthenticationID:fresh.result.reauthenticationID,recoveryCapabilityDigest:sha256(cap)});let finish,entered;const started=new Promise(resolve=>entered=resolve);
 f.config.appleRevoker=()=>{entered();return new Promise(resolve=>finish=resolve);};
 const pending=f.authority.deleteAccount(l.context,r);await started;
 await a.login(l.d);finish({revoked:true});await assert.rejects(pending,e=>e.code==='reauthenticationRequired');
 assert.equal(f.inspect('SELECT state FROM deletions')[0].state,'lockReconciled');
});

test('each normal migration transaction rolls back before commit and replays exact committed result after lost response and reopen',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const {old,waiting}=await phones(f);
 async function faulted(method,ctx,r){f.faults.beforeCommit=true;assert.throws(()=>f.authority[method](ctx,r),e=>e.code==='unavailable');f.faults.beforeCommit=false;f.faults.afterCommitResponseLost=true;assert.throws(()=>f.authority[method](ctx,r),e=>e.code==='responseLost');f.faults.afterCommitResponseLost=false;await f.restart();}
 const prepare=req({newPhoneID:waiting.d.deviceID,activationEpoch:old.credential.activationEpoch});await faulted('prepareMigration',old.context,prepare);
 const started=JSON.parse(f.authority.requestBytes(old.context,prepare.requestID));
 const checkpoint=req({migrationID:started.body.migration.migrationID,checkpointID:'checkpoint-fault',contentCommitment:'c'.repeat(64),activationEpoch:old.credential.activationEpoch});await faulted('checkpointMigration',old.context,checkpoint);
 const originalBytes=f.authority.requestBytes(old.context,checkpoint.requestID);assert.deepEqual(f.authority.checkpointMigration(old.context,checkpoint),JSON.parse(originalBytes));
 const activate=req({migrationID:started.body.migration.migrationID,checkpointID:'checkpoint-fault',contentCommitment:'c'.repeat(64),cloudSpaceID:'fixture-cloud'});await faulted('activateMigration',waiting.context,activate);
 const current={...waiting.context,activationEpoch:f.inspect("SELECT activation_epoch FROM accounts WHERE account_id='"+old.context.accountID+"'")[0].activation_epoch};const result=JSON.parse(f.authority.requestBytes(current,activate.requestID));assert.equal(result.body.result,'activated');
});
for(const step of ['lockReconciled','appleRevocation','backendDeleted'])test('delete persists and resumes after failure at '+step,async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());let a=await authSetup(f),l=await a.login(),fresh=await a.login(l.d),cap=randomBytes(32).toString('base64url');
 const r=req({reauthenticationID:fresh.result.reauthenticationID,recoveryCapabilityDigest:sha256(cap)});f.config.appleRevoker=async()=>({revoked:true});f.faults.lifecycleStep=step;
 await assert.rejects(f.authority.deleteAccount(l.context,r),e=>e.code==='unavailable');
 await f.restart();f.faults.lifecycleStep=undefined;a=await authSetup(f);await a.login(l.d);
 const result=await f.authority.deleteAccount(l.context,r);assert.equal(result.body.result,'deleted');assert.equal(f.authority.deleteStatus(req({deleteRequestID:r.requestID,recoveryCapability:cap})).status,'backendDeleted');
});
test('deletion blocks new starts and erases associated challenge and gift ledgers',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const a=await authSetup(f),l=await a.login(),fresh=await a.login(l.d),cap=randomBytes(32).toString('base64url');
 const r=req({reauthenticationID:fresh.result.reauthenticationID,recoveryCapabilityDigest:sha256(cap)});
 f.inspect("INSERT INTO qualifications VALUES('"+l.context.accountID+"','gifted') RETURNING *");
 await assert.rejects(f.authority.deleteAccount(l.context,r),e=>e.code==='unavailable');assert.throws(()=>f.authority.acquire(l.context,matchRequest(l,'during-delete')),e=>e.code==='migrationBlocked');
 f.config.appleRevoker=async()=>({revoked:true});await f.authority.deleteAccount(l.context,r);
 assert.equal(f.inspect("SELECT count(*) AS n FROM challenges WHERE device_id='"+l.d.deviceID+"'")[0].n,0);assert.equal(f.inspect('SELECT count(*) AS n FROM qualifications')[0].n,0);
});

test('after migration old phone fresh same-key login is waiting at current epoch and explicit same-key Watch registration works',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const {a,old,waiting}=await phones(f),watch=a.device();
 function register(phone){const c=a.auth.challenge(req({deviceID:watch.deviceID,devicePublicKey:watch.devicePublicKey}));const r=req({watchID:watch.deviceID,watchPublicKey:watch.devicePublicKey,challengeID:c.challengeID});r.deviceProof=challengeSignature(r,c.challenge,watch.privateKey);return a.auth.registerWatch(phone.context,r);}
 const firstWatch=register(old);
 const prepared=f.authority.prepareMigration(old.context,req({newPhoneID:waiting.d.deviceID,activationEpoch:old.credential.activationEpoch}));
 f.authority.checkpointMigration(old.context,req({migrationID:prepared.body.migration.migrationID,checkpointID:'last',contentCommitment:'d'.repeat(64),activationEpoch:old.credential.activationEpoch}));
 f.authority.activateMigration(waiting.context,req({migrationID:prepared.body.migration.migrationID,checkpointID:'last',contentCommitment:'d'.repeat(64),cloudSpaceID:'fixture-cloud'}));
 const current=await a.login(waiting.d),oldAgain=await a.login(old.d);assert.equal(oldAgain.result.receipt.body.result,'waitingMigration');assert.equal(oldAgain.credential.activationEpoch,current.credential.activationEpoch);
 assert.throws(()=>f.authority.acquire(oldAgain.context,matchRequest(oldAgain,'old-fresh')),e=>e.code==='activationMismatch');
 const rerecorded=register(current);assert.equal(rerecorded.credential.activationEpoch,current.credential.activationEpoch);
 const fields={method:'GET',path:'/v1/requests/not-known',requestID:'not-known',bodyBytes:Buffer.alloc(0)};
 const newLogin={d:watch,credential:rerecorded.credential};const proof=a.proof(newLogin,fields);const ctx=a.auth.authenticateRequest({...fields,authorization:'Bearer '+newLogin.credential.token,proof});assert.equal(ctx.activationEpoch,current.credential.activationEpoch);
 const oldLogin={d:watch,credential:firstWatch.credential};assert.throws(()=>a.auth.authenticateRequest({...fields,authorization:'Bearer '+oldLogin.credential.token,proof:a.proof(oldLogin,fields)}),e=>e.code==='unauthorized');
 const held=f.authority.acquire(ctx,{version:1,requestID:'reregistered-watch-start',matchID:'reregistered-watch-match',recordingDeviceID:watch.deviceID,activationEpoch:ctx.activationEpoch});assert.equal(held.body.result,'held');
 f.authority.terminate(current.context,req({matchID:held.body.matchID,lockID:held.body.lockID,recordingDeviceID:watch.deviceID,activationEpoch:ctx.activationEpoch,mode:'abnormal'}));
 const returnMigration=f.authority.prepareMigration(current.context,req({newPhoneID:old.d.deviceID,activationEpoch:current.credential.activationEpoch}));assert.equal(returnMigration.body.result,'waitingMigration');
 await assert.rejects(a.login(watch),e=>e.code==='unauthorized');
});
