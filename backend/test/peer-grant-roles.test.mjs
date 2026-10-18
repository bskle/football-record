import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {openHTTPFixture,challengeSignature} from './support.mjs';
import {canonicalJSON,sha256,verifySigned,makeReceipt} from '../src/receipt.mjs';
import {authorityState} from '../src/authority.mjs';
const req=fields=>({version:1,requestID:randomUUID(),...fields});
const path='/v1/peers/grants';
const grantRequest=(phone,local,remote,pairingID=randomUUID())=>req({localDeviceID:local.d.deviceID,remoteDeviceID:remote.d.deviceID,activationEpoch:phone.credential.activationEpoch,pairingID});
async function open(t){const h=await openHTTPFixture();t.after(()=>h.close());const phone=await h.login();return {h,phone};}
async function watch(h,phone){
 const d=h.a.device(),c=(await h.raw('/v1/auth/challenges',canonicalJSON(req({deviceID:d.deviceID,devicePublicKey:d.devicePublicKey})))).data;
 const r=req({watchID:d.deviceID,watchPublicKey:d.devicePublicKey,challengeID:c.challengeID});r.deviceProof=challengeSignature(r,c.challenge,d.privateKey);
 const registered=await h.call(phone,'/v1/devices/watches',r);assert.equal(registered.status,200);return {d,credential:registered.data.credential};
}
function roles(h,response,phone,localRole,remoteRole){
 assert.equal(response.status,200);assert.equal(verifySigned(h.f.receiptPublicKey,response.data),true);const g=response.data.body.peerGrant;
 assert.equal(g.localRole,localRole);assert.equal(g.remoteRole,remoteRole);assert.equal(g.activePhoneID,phone.d.deviceID);assert.equal(response.data.body.environment,'development');return g;
}
function seedLegacy(h,phone,r,grantID='legacy-'+randomUUID()){
 const db=authorityState(h.f.authority).db,local=db.prepare('SELECT * FROM devices WHERE device_id=?').get(r.localDeviceID),remote=db.prepare('SELECT * FROM devices WHERE device_id=?').get(r.remoteDeviceID);
 const grant={grantID,pairingID:r.pairingID,localDeviceID:local.device_id,remoteDeviceID:remote.device_id,localPublicKey:local.public_key,remotePublicKey:remote.public_key,expiresAt:h.f.clock.now()+3600};
 const result=makeReceipt(h.f.config,phone.context,r,'peerGrant','grantIssued',{}, {peerGrant:grant}),bytes=Buffer.from(canonicalJSON(result));
 // Controlled old-schema snapshot: genuine old receipt, without calling the new implementation.
 db.prepare('INSERT INTO requests VALUES(?,?,?,?,?)').run(phone.context.accountID,r.requestID,'peerGrant',sha256(canonicalJSON(r)),bytes);
 db.prepare('INSERT INTO peer_grants VALUES(?,?,?,?,?,?,?)').run(grantID,phone.context.accountID,phone.credential.activationEpoch,r.pairingID,r.localDeviceID,r.remoteDeviceID,bytes);
 assert.equal(verifySigned(h.f.receiptPublicKey,result),true);return {result,bytes,grantID};
}

test('actual HTTP phone auth and Watch registration issue signed role proof in both endpoint orders; tampering fails',async t=>{
 const {h,phone}=await open(t),w=await watch(h,phone);
 for(const [local,remote,localRole,remoteRole]of [[phone,w,'phone','watch'],[w,phone,'watch','phone']]){
  const r=grantRequest(phone,local,remote),response=await h.call(phone,path,r),g=roles(h,response,phone,localRole,remoteRole);
  assert.equal(g.localPublicKey,local.d.devicePublicKey);assert.equal(g.remotePublicKey,remote.d.devicePublicKey);assert.equal(response.data.body.requestDigest,sha256(canonicalJSON(r)));
  for(const change of [{localRole:remoteRole},{remoteRole:localRole},{activePhoneID:w.d.deviceID}])assert.equal(verifySigned(h.f.receiptPublicKey,{...response.data,body:{...response.data.body,peerGrant:{...g,...change}}}),false);
 }
});

test('roles and activePhoneID cannot be self-reported in peer grant HTTP requests',async t=>{
 const {h,phone}=await open(t),w=await watch(h,phone);
 for(const extra of [{role:'phone'},{localRole:'phone'},{remoteRole:'watch'},{activePhoneID:phone.d.deviceID},{roles:{local:'phone',remote:'watch'}}]){
  const response=await h.call(phone,path,{...grantRequest(phone,phone,w),...extra});assert.equal(response.status,422);assert.equal(response.data.code,'invalidPayload');
 }
 assert.equal(h.f.inspect('SELECT count(*) AS n FROM peer_grants')[0].n,0);
});

test('new Watch-Watch grant is rejected even when requested by the active phone',async t=>{
 const {h,phone}=await open(t),one=await watch(h,phone),two=await watch(h,phone);assert.equal((await h.call(phone,path,grantRequest(phone,one,two))).status,403);
});

test('new Phone-Phone grant is rejected for an existing legacy nonactive phone row',async t=>{
 const {h,phone}=await open(t),other=await h.login(),db=authorityState(h.f.authority).db;
 db.prepare("UPDATE devices SET role='phone' WHERE device_id=?").run(other.d.deviceID);
 assert.equal((await h.call(phone,path,grantRequest(phone,phone,other))).status,403);
});

test('unknown persisted endpoint role cannot become a signed role proof',async t=>{
 const {h,phone}=await open(t),w=await watch(h,phone);authorityState(h.f.authority).db.prepare("UPDATE devices SET role='legacy-other' WHERE device_id=?").run(w.d.deviceID);
 assert.equal((await h.call(phone,path,grantRequest(phone,phone,w))).status,403);
});

test('waiting cross-account missing and stale-epoch endpoints are rejected',async t=>{
 const {h,phone}=await open(t),w=await watch(h,phone),waiting=await h.login(),other=await h.login(undefined,{subject:'other-account'}),missing={d:h.a.device()};
 for(const endpoint of [waiting,other,missing])assert.equal((await h.call(phone,path,grantRequest(phone,phone,endpoint))).status,403);
 const db=authorityState(h.f.authority).db;db.prepare('UPDATE devices SET activation_epoch=activation_epoch+1 WHERE device_id=?').run(w.d.deviceID);
 assert.equal((await h.call(phone,path,grantRequest(phone,phone,w))).status,403);
 assert.equal((await h.call(phone,path,{...grantRequest(phone,phone,w),activationEpoch:phone.credential.activationEpoch+1})).status,403);
});

test('waiting phone and registered Watch cannot call grant issuance as the active phone',async t=>{
 const {h,phone}=await open(t),w=await watch(h,phone),waiting=await h.login();for(const caller of [waiting,w])assert.equal((await h.call(caller,path,grantRequest(phone,phone,w))).status,403);
});

test('the phone endpoint must be the current activePhoneID even if caller is active',async t=>{
 const {h,phone}=await open(t),w=await watch(h,phone),stale=await h.login();authorityState(h.f.authority).db.prepare("UPDATE devices SET role='phone' WHERE device_id=?").run(stale.d.deviceID);
 for(const [local,remote]of [[stale,w],[w,stale]])assert.equal((await h.call(phone,path,grantRequest(phone,local,remote))).status,403);
});

test('wrong caller key or signature cannot obtain a role grant',async t=>{
 const {h,phone}=await open(t),w=await watch(h,phone),r=grantRequest(phone,phone,w);
 assert.equal((await h.call(phone,path,r,{mutateProof:p=>({...p,keyID:w.credential.keyID})})).status,401);
 assert.equal((await h.call(phone,path,r,{mutateProof:p=>({...p,signature:Buffer.alloc(64).toString('base64url')})})).status,401);
 assert.equal(h.f.inspect('SELECT count(*) AS n FROM peer_grants')[0].n,0);
});

test('reopen replays original bytes; explicit renewal preserves pairing and grant IDs with new roles and expiry',async t=>{
 const {h,phone}=await open(t),w=await watch(h,phone),r=grantRequest(phone,w,phone),first=await h.call(phone,path,r),g=roles(h,first,phone,'watch','phone');
 await h.restart();assert.equal((await h.call(phone,path,r)).text,first.text);assert.equal((await h.call(phone,'/v1/requests/'+r.requestID,undefined,{method:'GET'})).text,first.text);
 h.f.clock.advance(3601);const renewed=await h.call(phone,path,{...r,requestID:randomUUID()}),next=roles(h,renewed,phone,'watch','phone');assert.equal(next.grantID,g.grantID);assert.equal(next.pairingID,g.pairingID);assert.ok(next.expiresAt>g.expiresAt);
 assert.equal((await h.call(phone,'/v1/requests/'+r.requestID,undefined,{method:'GET'})).text,first.text);
});

test('genuine old missing-role receipt is preserved byte-for-byte and only explicit renewal creates role proof',async t=>{
 const {h,phone}=await open(t),w=await watch(h,phone),r=grantRequest(phone,phone,w),old=seedLegacy(h,phone,r);
 await h.restart();assert.equal((await h.call(phone,path,r)).text,old.bytes.toString());assert.equal((await h.call(phone,'/v1/requests/'+r.requestID,undefined,{method:'GET'})).text,old.bytes.toString());assert.equal(old.result.body.peerGrant.localRole,undefined);
 const renewal=await h.call(phone,path,{...r,requestID:randomUUID()}),g=roles(h,renewal,phone,'phone','watch');assert.equal(g.grantID,old.grantID);assert.equal(g.pairingID,r.pairingID);
 assert.equal((await h.call(phone,path,r)).text,old.bytes.toString());assert.equal(verifySigned(h.f.receiptPublicKey,old.result),true);
});

test('historical Watch-Watch receipt replays unchanged but cannot be renewed into new proof',async t=>{
 const {h,phone}=await open(t),one=await watch(h,phone),two=await watch(h,phone),r=grantRequest(phone,one,two),old=seedLegacy(h,phone,r);
 await h.restart();assert.equal((await h.call(phone,path,r)).text,old.bytes.toString());const renewal=await h.call(phone,path,{...r,requestID:randomUUID()});assert.equal(renewal.status,403);
 assert.equal((await h.call(phone,'/v1/requests/'+r.requestID,undefined,{method:'GET'})).text,old.bytes.toString());const cache=authorityState(h.f.authority).db.prepare('SELECT result FROM peer_grants WHERE grant_id=?').get(old.grantID);assert.deepEqual(Buffer.from(cache.result),old.bytes);
});

test('same pairing cannot silently reverse endpoint binding or change original request intent',async t=>{
 const {h,phone}=await open(t),w=await watch(h,phone),r=grantRequest(phone,phone,w);assert.equal((await h.call(phone,path,r)).status,200);
 assert.equal((await h.call(phone,path,{...r,localDeviceID:w.d.deviceID,remoteDeviceID:phone.d.deviceID})).status,409);
 assert.equal((await h.call(phone,path,{...r,requestID:randomUUID(),localDeviceID:w.d.deviceID,remoteDeviceID:phone.d.deviceID})).status,409);
});

test('grant rollback and COMMIT response loss recover signed role proof over HTTP after reopen',async t=>{
 const {h,phone}=await open(t),w=await watch(h,phone),r=grantRequest(phone,phone,w);h.f.faults.beforeCommit=true;
 assert.equal((await h.call(phone,path,r)).status,503);h.f.faults.beforeCommit=false;assert.equal(h.f.inspect('SELECT count(*) AS n FROM peer_grants')[0].n,0);
 h.f.faults.dropResponseAfterOperation='peerGrant';await assert.rejects(h.call(phone,path,r));h.f.faults.dropResponseAfterOperation=undefined;await h.restart();
 const recovered=await h.call(phone,'/v1/requests/'+r.requestID,undefined,{method:'GET'});roles(h,recovered,phone,'phone','watch');assert.equal((await h.call(phone,path,r)).text,recovered.text);
});
