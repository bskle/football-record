import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {openHTTPFixture,challengeSignature,appleJWT} from './support.mjs';
import {sha256,canonicalJSON} from '../src/receipt.mjs';
const req=fields=>({version:1,requestID:randomUUID(),...fields});
const start=l=>req({matchID:'http-match-'+randomUUID(),recordingDeviceID:l.d.deviceID,activationEpoch:l.credential.activationEpoch});

test('real HTTP strict codec rejects duplicate unknown nested oversized and unsafe-number bodies without logging values',async t=>{
 const h=await openHTTPFixture();t.after(()=>h.close());
 for(const body of ['{"version":1,"version":1,"requestID":"duplicate","deviceID":"x","devicePublicKey":"x"}',JSON.stringify({version:1,requestID:'private',events:'FORBIDDEN-SENTINEL'}),JSON.stringify({version:1,requestID:'nested',deviceID:{name:'FORBIDDEN-SENTINEL'}}),'[1,2]',JSON.stringify({version:1,requestID:'oversized',data:'x'.repeat(17000)}),'{"version":1,"requestID":"unsafe","activationEpoch":9007199254740992}']){
  const response=await h.raw('/v1/auth/challenges',body);assert.equal(response.status,422);assert.equal(response.text.includes('FORBIDDEN-SENTINEL'),false);
 }
 assert.equal(JSON.stringify(h.logs).includes('FORBIDDEN-SENTINEL'),false);assert.equal(JSON.stringify(h.f.inspect('SELECT * FROM requests')).includes('FORBIDDEN-SENTINEL'),false);
 assert.equal((await h.raw('/unregistered','{}')).status,404);
});
test('real HTTP distinguishes 401 403 409 422 429 503 and PoP nonce/time tampering',async t=>{
 const h=await openHTTPFixture();t.after(()=>h.close());const l=await h.login(),waiting=await h.login();const r=start(l);
 assert.equal((await h.raw('/v1/locks/acquire',canonicalJSON(r))).status,401);
 assert.equal((await h.call(waiting,'/v1/locks/acquire',start(waiting))).status,403);
 assert.equal((await h.call(l,'/v1/locks/acquire',r,{mutateProof:p=>({...p,nonce:randomUUID()})})).status,401);
 assert.equal((await h.call(l,'/v1/locks/acquire',r,{mutateProof:p=>({...p,issuedAt:p.issuedAt-1})})).status,401);
 assert.equal((await h.call(l,'/v1/locks/acquire',r)).status,200);
 assert.equal((await h.call(l,'/v1/locks/acquire',{...r,matchID:'changed'})).status,409);
 assert.equal((await h.call(l,'/v1/locks/acquire',{...r,requestID:'bad',activationEpoch:0})).status,422);
 h.f.faults.beforeCommit=true;assert.equal((await h.call(l,'/v1/locks/acquire',{...r,requestID:'unavailable'})).status,503);h.f.faults.beforeCommit=false;
 const limited=await openHTTPFixture({rateLimit:{maxRequests:1,windowSeconds:60}});t.after(()=>limited.close());await limited.raw('/v1/auth/challenges','{}');const limit=await limited.raw('/v1/auth/challenges','{}');assert.equal(limit.status,429);assert.equal(limit.data.retryable,true);
});
test('socket response loss after acquire COMMIT survives restart and authenticated GET returns exact original bytes',async t=>{
 const h=await openHTTPFixture();t.after(()=>h.close());const l=await h.login(),r=start(l);
 // Consume the PoP first; disconnect specifically after the business COMMIT.
 h.f.faults.dropResponseAfterOperation='acquire';await assert.rejects(h.call(l,'/v1/locks/acquire',r));h.f.faults.dropResponseAfterOperation=undefined;
 await h.restart();const query=await h.call(l,'/v1/requests/'+r.requestID,undefined,{method:'GET'});assert.equal(query.status,200);assert.equal(query.data.body.result,'held');
 assert.equal((await h.call(l,'/v1/locks/acquire',r)).text,query.text);
 const status=await h.call(l,'/v1/locks/status',req({acquireRequestID:r.requestID,matchID:r.matchID,lockID:query.data.body.lockID,recordingDeviceID:r.recordingDeviceID,activationEpoch:r.activationEpoch,nonce:'fresh-http-status'}));assert.equal(status.data.body.status,'held');
 const other=await h.login(undefined,{subject:'other-identity'});assert.equal((await h.call(other,'/v1/requests/'+r.requestID,undefined,{method:'GET'})).status,404);
});
test('auth COMMIT disconnect recovers original session with original IDs and fresh device proof over real HTTP',async t=>{
 const h=await openHTTPFixture();t.after(()=>h.close());const d=h.a.device();
 const challenge=await h.raw('/v1/auth/challenges',canonicalJSON(req({deviceID:d.deviceID,devicePublicKey:d.devicePublicKey})));
 const r=req({challengeID:challenge.data.challengeID,identityToken:appleJWT({iss:'https://appleid.apple.com',sub:'http-auth-lost-sub',aud:'test.football',nonce:sha256(challenge.data.challenge),iat:h.f.clock.now(),exp:h.f.clock.now()+300}),authorizationCode:'transient',deviceID:d.deviceID,devicePublicKey:d.devicePublicKey,cloudSpaceID:'fixture-cloud'});r.deviceProof=challengeSignature(r,challenge.data.challenge,d.privateKey);
 h.f.faults.dropResponseAfterOperation='authenticate';await assert.rejects(h.raw('/v1/auth/apple',canonicalJSON(r)));h.f.faults.dropResponseAfterOperation=undefined;
 const claims=h.f.inspect("SELECT session_id,token_hash FROM sessions WHERE device_id='"+d.deviceID+"'")[0];await h.restart();
 const recover=req({authRequestID:r.requestID,deviceID:d.deviceID,keyID:d.keyID,nonce:randomUUID(),issuedAt:h.f.clock.now()});const {signRecover}=await import('../src/device-auth.mjs');recover.deviceProof=signRecover(d.privateKey,recover);
 const result=await h.raw('/v1/auth/recover',canonicalJSON(recover));assert.equal(result.status,200);assert.equal(result.data.credential.sessionID,claims.session_id);assert.equal(sha256(result.data.credential.token),claims.token_hash);
});
for(const kind of ['normal','lost'])test(kind+' activation COMMIT disconnect restores original receipt by fresh login and GET; old auth recover is revoked',async t=>{
 const h=await openHTTPFixture();t.after(()=>h.close());const old=await h.login(),waiting=await h.login();let migration,activate,path;
 if(kind==='normal'){
  migration=(await h.call(old,'/v1/migrations/prepare',req({newPhoneID:waiting.d.deviceID,activationEpoch:old.credential.activationEpoch}))).data.body.migration;
  await h.call(old,'/v1/migrations/checkpoint',req({migrationID:migration.migrationID,checkpointID:'wire-checkpoint',contentCommitment:'e'.repeat(64),activationEpoch:old.credential.activationEpoch}));
  activate=req({migrationID:migration.migrationID,checkpointID:'wire-checkpoint',contentCommitment:'e'.repeat(64),cloudSpaceID:'fixture-cloud'});path='/v1/migrations/activate';
 }else{
  migration=(await h.call(waiting,'/v1/migrations/lost',req({newPhoneID:waiting.d.deviceID,cloudSpaceID:'fixture-cloud'}))).data.body.migration;h.f.clock.set(migration.eligibleAt);
  const fresh=await h.login(waiting.d);activate=req({migrationID:migration.migrationID,reauthenticationID:fresh.result.reauthenticationID});path='/v1/migrations/force';
 }
 h.f.faults.dropResponseAfterOperation=kind==='normal'?'activateMigration':'forceMigration';await assert.rejects(h.call(waiting,path,activate));h.f.faults.dropResponseAfterOperation=undefined;await h.restart();
 const recover=req({authRequestID:waiting.r.requestID,deviceID:waiting.d.deviceID,keyID:waiting.d.keyID,nonce:randomUUID(),issuedAt:h.f.clock.now()});const {signRecover}=await import('../src/device-auth.mjs');recover.deviceProof=signRecover(waiting.d.privateKey,recover);assert.equal((await h.raw('/v1/auth/recover',canonicalJSON(recover))).data.status,'knownRevoked');
 const current=await h.login(waiting.d),result=await h.call(current,'/v1/requests/'+activate.requestID,undefined,{method:'GET'});assert.equal(result.status,200);assert.equal(result.data.body.result,'activated');assert.equal(result.data.body.requestID,activate.requestID);assert.equal(result.data.body.activationEpoch,current.credential.activationEpoch);
});
test('delete COMMIT disconnect can only recover original backend result by body capability with no session',async t=>{
 const h=await openHTTPFixture();t.after(()=>h.close());const l=await h.login(),fresh=await h.login(l.d),cap=randomBytes(32).toString('base64url');h.f.config.appleRevoker=async()=>({revoked:true});
 const r=req({reauthenticationID:fresh.result.reauthenticationID,recoveryCapabilityDigest:sha256(cap)});h.f.faults.dropResponseAfterOperation='deleteAccount';await assert.rejects(h.call(l,'/v1/accounts/delete',r));h.f.faults.dropResponseAfterOperation=undefined;await h.restart();
 const status=await h.raw('/v1/accounts/delete-status',canonicalJSON(req({deleteRequestID:r.requestID,recoveryCapability:cap})));assert.equal(status.data.status,'backendDeleted');assert.equal(status.data.receipt.body.requestID,r.requestID);
 assert.equal((await h.call(l,'/v1/requests/'+r.requestID,undefined,{method:'GET'})).status,401);assert.equal(JSON.stringify(h.logs).includes(cap),false);
});

test('explicit Watch registration and peer grant refresh preserve device roles and grant ID; other Watch cannot attest the recorder lock',async t=>{
 const h=await openHTTPFixture();t.after(()=>h.close());const phone=await h.login();
 async function watch(){const d=h.a.device(),challenge=(await h.raw('/v1/auth/challenges',canonicalJSON(req({deviceID:d.deviceID,devicePublicKey:d.devicePublicKey})))).data;const r=req({watchID:d.deviceID,watchPublicKey:d.devicePublicKey,challengeID:challenge.challengeID});r.deviceProof=challengeSignature(r,challenge.challenge,d.privateKey);const registered=await h.call(phone,'/v1/devices/watches',r);assert.equal(registered.status,200);return {d,credential:registered.data.credential};}
 const one=await watch(),two=await watch(),pair={localDeviceID:phone.d.deviceID,remoteDeviceID:one.d.deviceID,activationEpoch:phone.credential.activationEpoch,pairingID:'stable-pair'};
 const first=await h.call(phone,'/v1/peers/grants',req(pair));assert.equal(first.status,200);h.f.clock.advance(3601);
 const refreshed=await h.call(phone,'/v1/peers/grants',req(pair));assert.equal(refreshed.data.body.peerGrant.grantID,first.data.body.peerGrant.grantID);assert.ok(refreshed.data.body.peerGrant.expiresAt>first.data.body.peerGrant.expiresAt);
 const acquire=req({matchID:'watch-one-match',recordingDeviceID:one.d.deviceID,activationEpoch:phone.credential.activationEpoch}),lock=await h.call(one,'/v1/locks/acquire',acquire);assert.equal(lock.status,200);
 const query=req({acquireRequestID:acquire.requestID,matchID:acquire.matchID,lockID:lock.data.body.lockID,recordingDeviceID:one.d.deviceID,activationEpoch:phone.credential.activationEpoch,nonce:'current-watch-status'});
 assert.equal((await h.call(two,'/v1/locks/status',query)).status,403);assert.equal((await h.call(one,'/v1/locks/status',query)).data.body.status,'held');
 const normal=req({matchID:acquire.matchID,lockID:lock.data.body.lockID,recordingDeviceID:one.d.deviceID,activationEpoch:phone.credential.activationEpoch,mode:'normal',cloudConfirmationID:'opaque-cloud-save',contentCommitment:'f'.repeat(64)});assert.equal((await h.call(phone,'/v1/locks/terminate',normal)).status,403);assert.equal((await h.call(one,'/v1/locks/terminate',normal)).data.body.result,'releasedNormal');
});
test('reference server rejects non-loopback binding and production factory cannot accept development JWT factory',async t=>{
 const h=await openHTTPFixture();t.after(()=>h.close());const {createHTTPServer}=await import('../src/http.mjs'),{createAuthority}=await import('../src/authority.mjs'),{createDeviceAuth}=await import('../src/device-auth.mjs');
 const server=createHTTPServer({authority:h.f.authority,appleVerifier:h.a.verifier,deviceAuth:h.a.auth});assert.throws(()=>server.listen(0,'0.0.0.0'),/loopback/);
 const {tempDB}=await import('./support.mjs');const production=createAuthority({...h.f.config,databasePath:tempDB(),environment:'production'});t.after(()=>production.close());assert.throws(()=>createDeviceAuth({authority:production,appleVerifier:h.a.verifier}),/environment mismatch/);
});

test('CLI requires explicit development keys and actually listens on loopback, reopening the same database',async()=>{
 const {spawn}=await import('node:child_process'),{mkdtempSync,writeFileSync}=await import('node:fs'),{tmpdir}=await import('node:os'),{join}=await import('node:path'),{generateKeyPairSync}=await import('node:crypto');
 const directory=mkdtempSync(join(tmpdir(),'football-cli-'));
 const keys={account:join(directory,'account.key'),token:join(directory,'token.key'),receipt:join(directory,'receipt.pem')};
 writeFileSync(keys.account,randomBytes(32),{mode:0o600});writeFileSync(keys.token,randomBytes(32),{mode:0o600});writeFileSync(keys.receipt,generateKeyPairSync('ed25519').privateKey.export({type:'pkcs8',format:'pem'}),{mode:0o600});
 const env={...process.env,FOOTBALL_AUTH_ENV:'development',FOOTBALL_AUTH_DB:join(directory,'authority.sqlite'),FOOTBALL_AUTH_ACCOUNT_KEY_FILE:keys.account,FOOTBALL_AUTH_TOKEN_KEY_FILE:keys.token,FOOTBALL_AUTH_RECEIPT_KEY_FILE:keys.receipt,FOOTBALL_AUTH_APPLE_AUDIENCES:'test.football',FOOTBALL_AUTH_PORT:'0'};
 async function run(){const child=spawn(process.execPath,['backend/src/server.mjs'],{env,stdio:['ignore','pipe','pipe']});let output='',errors='';child.stderr.on('data',x=>errors+=x);const ready=await new Promise((resolve,reject)=>{const deadline=setTimeout(()=>{child.kill();reject(Error('CLI startup timeout'));},5000);child.on('exit',code=>{clearTimeout(deadline);reject(Error('CLI exited '+code+':'+errors));});child.stdout.on('data',chunk=>{output+=chunk;for(const line of output.split('\n')){try{const r=JSON.parse(line);if(r.code==='listening'){clearTimeout(deadline);resolve(r);}}catch{}}});});assert.equal(ready.host,'127.0.0.1');assert.equal((await fetch(`http://127.0.0.1:${ready.port}/unknown`)).status,404);await new Promise(resolve=>{child.once('exit',resolve);child.kill('SIGTERM');});assert.equal(errors.includes('ExperimentalWarning'),true);return ready;}
 const first=await run(),second=await run();assert.equal(first.environment,'development');assert.equal(second.environment,'development');
 const failed=spawn(process.execPath,['backend/src/server.mjs'],{env:{...env,FOOTBALL_AUTH_TOKEN_KEY_FILE:''},stdio:['ignore','pipe','pipe']});let error='';failed.stderr.on('data',x=>error+=x);assert.equal(await new Promise(resolve=>failed.on('exit',resolve)),1);assert.equal(error.includes('unavailable'),true);
});
