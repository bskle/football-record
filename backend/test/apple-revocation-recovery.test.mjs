import nodeTest from 'node:test';
const test=(name,fn)=>nodeTest(name,{timeout:5000},fn);
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import {openRevocationAuthority} from './apple-revocation-support.mjs';
import {sha256} from '../src/receipt.mjs';
import {authorityState} from '../src/authority.mjs';
const req=fields=>({version:1,requestID:randomUUID(),...fields});
async function deletion(h){const login=await h.login(),fresh=await h.login(login.d),capability=randomBytes(32).toString('base64url');return {login,fresh,capability,request:req({reauthenticationID:fresh.result.reauthenticationID,recoveryCapabilityDigest:sha256(capability)})};}
const exchangeCount=h=>h.apple.requests.filter(r=>r.path==='/auth/token').length;
const revokeCount=h=>h.apple.requests.filter(r=>r.path==='/auth/revoke').length;

test('verified transient material is bound to exact original account device key epoch and consumed on delete',async t=>{
 const h=await openRevocationAuthority();t.after(()=>h.close());const d=await deletion(h),state=authorityState(h.f.authority),material=state.transientReauthCodes.get(d.fresh.result.reauthenticationID);
 assert.equal(typeof material,'object');assert.equal(material.authorizationCode,d.fresh.request.authorizationCode);assert.deepEqual(material.binding,{accountID:d.login.context.accountID,deviceID:d.login.d.deviceID,keyID:d.login.context.keyID,activationEpoch:d.login.context.activationEpoch,reauthenticationID:d.fresh.result.reauthenticationID});
 assert.equal(material.expectedApple.subject,'account-subject-SENTINEL');assert.equal(material.expectedApple.audience,'test.football');
 const result=await h.call(d.login,'/v1/accounts/delete',d.request);assert.equal(result.status,200);assert.equal(result.data.body.requestDigest,sha256(JSON.stringify(d.request,Object.keys(d.request).sort())));assert.equal(exchangeCount(h),1);assert.equal(revokeCount(h),1);
 assert.equal(state.transientReauthCodes.size,0);assert.equal(material.authorizationCode,'');assert.equal(material.expectedApple,undefined);
});
for(const phase of ['exchange','revoke'])test(phase+' unknown outcome never replays code; reopen requires fresh same-key auth and keeps original delete intent',async t=>{
 const h=await openRevocationAuthority();t.after(()=>h.close());const d=await deletion(h);h.apple.controls[phase+'Disconnect']=true;
 const failed=await h.call(d.login,'/v1/accounts/delete',d.request);assert.equal(failed.status,403);assert.equal(failed.data.code,'reauthenticationRequired');assert.equal(exchangeCount(h),1);
 assert.equal((await h.call(d.login,'/v1/accounts/delete',d.request)).status,403);assert.equal(exchangeCount(h),1);
 const original=h.f.inspect('SELECT request_digest,delete_request_id FROM deletions')[0];await h.restart();h.apple.controls[phase+'Disconnect']=false;
 assert.equal((await h.call(d.login,'/v1/requests/'+d.request.requestID,undefined,{method:'GET'})).status,503);
 assert.equal((await h.call(d.login,'/v1/accounts/delete',d.request)).status,403);assert.equal(exchangeCount(h),1);
 await h.login(d.login.d);assert.deepEqual(h.f.inspect('SELECT request_digest,delete_request_id FROM deletions')[0],original);
 assert.equal((await h.call(d.login,'/v1/accounts/delete',d.request)).data.body.result,'deleted');assert.equal(exchangeCount(h),2);
 const recovered=await h.raw('/v1/accounts/delete-status',req({deleteRequestID:d.request.requestID,recoveryCapability:d.capability}));assert.equal(recovered.data.receipt.body.requestID,d.request.requestID);assert.equal(recovered.data.receipt.body.requestDigest,original.request_digest);
});
test('revoke succeeds but SQL failure cannot persist appleRevocation; fresh auth resumes same saga',async t=>{
 const h=await openRevocationAuthority();t.after(()=>h.close());const d=await deletion(h);h.f.faults.lifecycleStep='appleRevocation';
 assert.equal((await h.call(d.login,'/v1/accounts/delete',d.request)).status,503);assert.equal(revokeCount(h),1);assert.equal(h.f.inspect('SELECT state FROM deletions')[0].state,'lockReconciled');
 await h.restart();h.f.faults.lifecycleStep=undefined;await h.login(d.login.d);assert.equal((await h.call(d.login,'/v1/accounts/delete',d.request)).status,200);assert.equal(revokeCount(h),2);
});
test('backend commit lost response recovers original signed delete result by capability with revoked credentials',async t=>{
 const h=await openRevocationAuthority();t.after(()=>h.close());const d=await deletion(h);h.f.faults.dropResponseAfterOperation='deleteAccount';await assert.rejects(h.call(d.login,'/v1/accounts/delete',d.request));h.f.faults.dropResponseAfterOperation=undefined;await h.restart();
 assert.equal((await h.call(d.login,'/v1/requests/'+d.request.requestID,undefined,{method:'GET'})).status,401);const status=await h.raw('/v1/accounts/delete-status',req({deleteRequestID:d.request.requestID,recoveryCapability:d.capability}));assert.equal(status.data.status,'backendDeleted');assert.equal(status.data.receipt.body.requestID,d.request.requestID);
});
test('revoke await then refreshed proof CAS cannot advance old pending authorization',async t=>{
 const h=await openRevocationAuthority();t.after(()=>h.close());const d=await deletion(h);let entered,finish;const started=new Promise(resolve=>entered=resolve);h.apple.controls.revokeEntered=entered;h.apple.controls.revokePause=new Promise(resolve=>finish=resolve);
 const pending=h.call(d.login,'/v1/accounts/delete',d.request);await Promise.race([started,pending.then(()=>{throw Error('adapter did not reach fixture network');})]);await h.login(d.login.d);finish();const result=await pending;assert.equal(result.status,403);assert.equal(h.f.inspect('SELECT state FROM deletions')[0].state,'lockReconciled');
 h.apple.controls.revokePause=undefined;assert.equal((await h.call(d.login,'/v1/accounts/delete',d.request)).status,200);
});
test('revoke await then epoch fault CAS cannot delete the account',async t=>{
 const h=await openRevocationAuthority();t.after(()=>h.close());const d=await deletion(h);let entered,finish;const started=new Promise(resolve=>entered=resolve);h.apple.controls.revokeEntered=entered;h.apple.controls.revokePause=new Promise(resolve=>finish=resolve);
 const pending=h.call(d.login,'/v1/accounts/delete',d.request);await Promise.race([started,pending.then(()=>{throw Error('adapter did not reach fixture network');})]);h.f.inspect("UPDATE accounts SET activation_epoch=activation_epoch+100 WHERE account_id='"+d.login.context.accountID+"' RETURNING *");finish();assert.equal((await pending).status,403);assert.equal(h.f.inspect('SELECT state FROM deletions')[0].state,'lockReconciled');assert.equal(revokeCount(h),1);
});
test('concurrent actual HTTP deletes consume the original reauth once and send one exchange/revoke',async t=>{
 const h=await openRevocationAuthority();t.after(()=>h.close());const d=await deletion(h);let entered,finish;const started=new Promise(resolve=>entered=resolve);h.apple.controls.exchangeEntered=entered;h.apple.controls.exchangePause=new Promise(resolve=>finish=resolve);
 const first=h.call(d.login,'/v1/accounts/delete',d.request);await Promise.race([started,first.then(()=>{throw Error('adapter did not reach fixture network');})]);const second=await h.call(d.login,'/v1/accounts/delete',d.request);assert.equal(second.status,403);finish();assert.equal((await first).status,200);assert.equal(exchangeCount(h),1);assert.equal(revokeCount(h),1);
});
test('expired close/reopen or mismatched binding destroys transient material before any outbound exchange',async t=>{
 const h=await openRevocationAuthority();t.after(()=>h.close());const d=await deletion(h),state=authorityState(h.f.authority),material=state.transientReauthCodes.get(d.fresh.result.reauthenticationID);
 material.binding={...material.binding,keyID:'different-key'};assert.equal((await h.call(d.login,'/v1/accounts/delete',d.request)).status,403);assert.equal(exchangeCount(h),0);assert.equal(material.authorizationCode,'');
 await h.login(d.login.d);const current=[...state.transientReauthCodes.values()][0];h.f.clock.advance(301);assert.equal((await h.call(d.login,'/v1/accounts/delete',d.request)).status,403);assert.equal(state.transientReauthCodes.size,0);assert.equal(current.authorizationCode,'');
 await h.login(d.login.d);const closing=[...state.transientReauthCodes.values()][0];await h.restart();assert.equal(state.transientReauthCodes.size,0);assert.equal(closing.authorizationCode,'');
});

test('a genuine verified bundle from another Apple account cannot be substituted under the original binding',async t=>{
 const h=await openRevocationAuthority();t.after(()=>h.close());const d=await deletion(h),material=authorityState(h.f.authority).transientReauthCodes.get(d.fresh.result.reauthenticationID),other=await h.apple.input();
 material.authorizationCode=other.authorizationCode;material.expectedApple=other.expectedApple;
 assert.equal((await h.call(d.login,'/v1/accounts/delete',d.request)).status,403);assert.equal(exchangeCount(h),0);assert.equal(material.authorizationCode,'');
});
