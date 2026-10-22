import test from 'node:test';
import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import * as deviceAuth from '../src/device-auth.mjs';

test('account mapping keeps original HMAC bytes and identity isolation',()=>{
  assert.equal(typeof deviceAuth.accountIDForAppleIdentity,'function');
  const map=deviceAuth.accountIDForAppleIdentity,key=Buffer.alloc(32,7);
  const identity={issuer:'https://appleid.apple.com',subject:'fixture-primary'};
  const original=createHmac('sha256',key).update(identity.issuer+'\n'+identity.subject).digest('hex');
  assert.equal(map(key,identity),original);assert.match(original,/^[a-f0-9]{64}$/);
  assert.equal(map(key,identity),map(key,{...identity}));
  for(const changed of [{...identity,subject:'alternate'},{...identity,issuer:'other-issuer'},{...identity,subject:' fixture-primary'}])assert.notEqual(map(key,changed),original);
  assert.notEqual(map(Buffer.alloc(32,8),identity),original);
  assert.notEqual(map(key,{...identity,subject:'\u00e9'}),map(key,{...identity,subject:'e\u0301'}));
});

import {mkdtempSync,readFileSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {generateKeyPairSync,randomBytes,randomUUID} from 'node:crypto';
import {rawPublicKey,sha256,canonicalJSON} from '../src/receipt.mjs';
import {appleJWT,appleJWKS,fixtureClock,challengeSignature} from './support.mjs';
const helperURL=new URL('../../scripts/native/m4-authority-fixture.mjs',import.meta.url);
const helper=()=>import(helperURL);
const newDB=()=>join(mkdtempSync(join(tmpdir(),'native-m4-fixture-test-')),'authority.sqlite');
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const quote=s=>'"'+s.replaceAll('"','""')+'"';
function snapshot(path){
  const db=new DatabaseSync(path,{readOnly:true});
  try{return db.prepare("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all().map(({name})=>{
    const columns=db.prepare('PRAGMA table_info('+quote(name)+')').all().map(x=>x.name);
    const rows=db.prepare('SELECT * FROM '+quote(name)).all().map(row=>columns.map(key=>{
      const value=row[key];return value instanceof Uint8Array?['blob',Buffer.from(value).toString('hex')]:[typeof value,value];
    })).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b)));
    return {name,columns,rows};
  });}finally{db.close();}
}
function assertNoStoredSecrets(path,secrets){for(const suffix of ['', '-wal','-shm'])if(existsSync(path+suffix)){const bytes=readFileSync(path+suffix);for(const secret of secrets)assert.equal(bytes.includes(Buffer.isBuffer(secret)?secret:Buffer.from(secret)),false,'secret absent from DB/WAL/SHM');}}
function rows(path,sql,...params){const db=new DatabaseSync(path,{readOnly:true});try{return db.prepare(sql).all(...params);}finally{db.close();}}
const count=(path,table)=>rows(path,'SELECT count(*) AS n FROM '+quote(table))[0].n;
const claims=(nonce,clock,overrides={})=>({iss:'https://appleid.apple.com',sub:'fixture-primary',aud:'test.football',nonce,iat:clock.now(),exp:clock.now()+60,...overrides});
function assertNoSecrets(value,secrets=[]){
  const text=JSON.stringify(value);
  for(const field of ['credential','privateKey','identityToken','authorizationCode','accountHMACKey','tokenDerivationKey','subject','issuer'])assert.equal(text.includes('"'+field+'"'),false,'secret field '+field);
  for(const secret of secrets)assert.equal(text.includes(secret),false,'secret sentinel absent');
}
async function raw(f,path,body,headers={}){
  const response=await fetch(f.metadata.baseURL+path,{method:'POST',headers:{'content-type':'application/json',...headers},body:canonicalJSON(body)});
  return {status:response.status,data:await response.json()};
}
function device(){const pair=generateKeyPairSync('ed25519');const publicKey=rawPublicKey(pair.privateKey);return {deviceID:randomUUID(),privateKey:pair.privateKey,devicePublicKey:publicKey,keyID:sha256(publicKey)};}
async function prepare(f,d=device(),identity='primary'){
  const c=await raw(f,'/v1/auth/challenges',{version:1,requestID:randomUUID(),deviceID:d.deviceID,devicePublicKey:d.devicePublicKey});
  assert.equal(c.status,200);
  const apple=f.issueApple({purpose:'authentication',nonce:sha256(c.data.challenge),identity});
  const request={version:1,requestID:randomUUID(),challengeID:c.data.challengeID,...apple,deviceID:d.deviceID,devicePublicKey:d.devicePublicKey,cloudSpaceID:'fixture-cloud'};
  request.deviceProof=challengeSignature(request,c.data.challenge,d.privateKey);return {d,request,challenge:c.data};
}
async function observe(f,identity='primary'){
  const begin=f.beginObservation(),apple=f.issueApple({purpose:'observation',nonce:begin.nonce,identity});
  return f.observeIdentity({observationID:begin.observationID,identityToken:apple.identityToken});
}

test('empty authority initializes only schema metadata and epoch zero',async t=>{
  const {openM4AuthorityFixture}=await helper(),databasePath=newDB();
  const f=await openM4AuthorityFixture({databasePath});t.after(()=>f.close());
  assert.match(f.metadata.baseURL,/^http:\/\/127\.0\.0\.1:\d+$/);assert.equal(f.metadata.environment,'development');
  assertNoSecrets(f.metadata);assert.equal(Object.hasOwn(f.metadata,'accountID'),false);
  const all=snapshot(databasePath);
  assert.ok(all.length>=20);
  for(const table of all)if(!['metadata','epoch_allocator'].includes(table.name))assert.equal(table.rows.length,0,table.name+' starts empty');
  assert.equal(rows(databasePath,'SELECT value FROM epoch_allocator WHERE id=1')[0].value,0);
  assert.equal(count(databasePath,'metadata'),1);
  assert.ok(existsSync(databasePath));
});

test('empty authority uses actual elapsed Unix seconds and closes idempotently',async()=>{
  const {openM4AuthorityFixture}=await helper(),f=await openM4AuthorityFixture();
  const before=f.metadata.now;assert.ok(Math.abs(before-Math.floor(Date.now()/1000))<=2);
  await pause(1050);assert.ok(f.metadata.now>before);
  const baseURL=f.metadata.baseURL;await f.close();await f.close();
  await assert.rejects(fetch(baseURL+'/v1/none'));assert.throws(()=>f.beginObservation(),e=>e.code==='fixtureClosed');
});

test('empty authority refuses existing or relative database without replacing it',async()=>{
  const {openM4AuthorityFixture}=await helper(),databasePath=newDB();
  const f=await openM4AuthorityFixture({databasePath});await f.close();const old=readFileSync(databasePath);
  await assert.rejects(openM4AuthorityFixture({databasePath}));assert.equal(readFileSync(databasePath).equals(old),true);
  await assert.rejects(openM4AuthorityFixture({databasePath:'relative.sqlite'}));
});

import {createAuthority,authorityState} from '../src/authority.mjs';
import {createDevelopmentAppleVerifier,createAppleVerifier,isVerifiedApple} from '../src/apple-verifier.mjs';
async function observerFixture(t,{fetchJWKS=async()=>structuredClone(appleJWKS),clock=fixtureClock(),verifier}={}){
  const databasePath=newDB(),authority=createAuthority({databasePath,clock,environment:'development',accountHMACKey:randomBytes(32),tokenDerivationKey:randomBytes(32),receiptPrivateKey:generateKeyPairSync('ed25519').privateKey});
  t.after(()=>authority.close());let generation=0;
  const genuine=verifier??createDevelopmentAppleVerifier({audiences:['test.football'],clock,fetchJWKS});
  const {createM4IdentityObserver}=await helper();assert.equal(typeof createM4IdentityObserver,'function');
  const observer=createM4IdentityObserver({authority,appleVerifier:genuine,namespace:'test-observer',getGeneration:()=>generation});
  return {databasePath,authority,clock,verifier:genuine,observer,advanceGeneration:()=>generation++};
}

test('identity observation verifies a distinct nonce without any SQL write',async t=>{
  const f=await observerFixture(t),before=snapshot(f.databasePath);
  const begin=f.observer.beginObservation();assert.match(begin.nonce,/^[a-f0-9]{64}$/);assert.equal(begin.expiresAt-begin.issuedAt,60);
  const observation=await f.observer.observeIdentity({observationID:begin.observationID,identityToken:appleJWT(claims(begin.nonce,f.clock))});
  assert.equal(observation.kind,'currentIdentity');assert.match(observation.accountID,/^[a-f0-9]{64}$/);assertNoSecrets(observation);
  for(const field of ['accountExists','registered','active','activationEpoch','startGrant'])assert.equal(Object.hasOwn(observation,field),false,field);
  const second=f.observer.beginObservation();assert.notEqual(begin.nonce,second.nonce);
  const again=await f.observer.observeIdentity({observationID:second.observationID,identityToken:appleJWT(claims(second.nonce,f.clock))});
  assert.equal(again.accountID,observation.accountID);
  const alternate=f.observer.beginObservation();
  const other=await f.observer.observeIdentity({observationID:alternate.observationID,identityToken:appleJWT(claims(alternate.nonce,f.clock,{sub:'alternate-subject'}))});
  assert.notEqual(other.accountID,observation.accountID);assert.deepEqual(snapshot(f.databasePath),before);
});

test('identity observation rejects unbranded copied or production verifiers before calling verify',async t=>{
  const f=await observerFixture(t),{createM4IdentityObserver}=await helper();let calls=0;
  const fake={environment:'development',verify:async()=>{calls++;return {issuer:'https://appleid.apple.com',subject:'FAKE-IDENTITY',issuedAt:f.clock.now(),environment:'development'};}};
  const before=snapshot(f.databasePath);
  for(const appleVerifier of [fake,{...f.verifier},createAppleVerifier({audiences:['test.football'],clock:f.clock})])assert.throws(()=>createM4IdentityObserver({authority:f.authority,appleVerifier,namespace:'test-observer',getGeneration:()=>0}),e=>e.code==='fixtureUnauthorized');
  assert.equal(calls,0);assert.deepEqual(snapshot(f.databasePath),before);
});

test('identity observation is one-use expires and rejects old issuance or copied identities',async t=>{
  const f=await observerFixture(t),before=snapshot(f.databasePath),b=f.observer.beginObservation();
  const token=appleJWT(claims(b.nonce,f.clock));
  await f.observer.observeIdentity({observationID:b.observationID,identityToken:token});
  await assert.rejects(f.observer.observeIdentity({observationID:b.observationID,identityToken:token}),e=>e.code==='fixtureUnauthorized');
  const expired=f.observer.beginObservation();f.clock.advance(61);
  await assert.rejects(f.observer.observeIdentity({observationID:expired.observationID,identityToken:appleJWT(claims(expired.nonce,f.clock))}),e=>e.code==='fixtureUnauthorized');
  const old=f.observer.beginObservation();await assert.rejects(f.observer.observeIdentity({observationID:old.observationID,identityToken:appleJWT(claims(old.nonce,f.clock,{iat:f.clock.now()-1}))}),e=>e.code==='fixtureUnauthorized');
  const copied=f.observer.beginObservation(),verified=await f.verifier.verify(appleJWT(claims(copied.nonce,f.clock)),copied.nonce);
  assert.equal(isVerifiedApple({...verified},'development'),false);
  await assert.rejects(f.observer.observeIdentity({observationID:copied.observationID,identityToken:{...verified}}),e=>e.code==='fixtureUnauthorized');
  await assert.rejects(f.observer.observeIdentity({observationID:'unknown',identityToken:token}),e=>e.code==='fixtureUnauthorized');
  assert.deepEqual(snapshot(f.databasePath),before);
});

test('identity observation rejects real cryptographic and claim failures with all tables unchanged',async t=>{
  const cases=[
    ['issuer',{iss:'https://attacker.invalid'}],['audience',{aud:'another.app'}],['nonce',{nonce:'wrong'}],
    ['expired',{iat:1800000000-120,exp:1800000000-61}],['future-iat',{iat:1800000061,exp:1800000300}],['iat-after-exp',{iat:1800000055,exp:1800000050}],
    ['alg',{}, {alg:'HS256',kid:'fixture-apple'}],['kid',{}, {alg:'RS256',kid:'unknown'}],['signature',{},undefined,'signature'],
    ['kty',{},undefined,'kty'],['use',{},undefined,'use'],['key-alg',{},undefined,'key-alg']
  ];
  for(const [name,overrides,header,alter]of cases)await t.test(name,async st=>{
    const jwks=structuredClone(appleJWKS);
    if(alter==='kty')jwks.keys[0].kty='EC';if(alter==='use')jwks.keys[0].use='enc';if(alter==='key-alg')jwks.keys[0].alg='RS512';
    const f=await observerFixture(st,{fetchJWKS:async()=>jwks}),before=snapshot(f.databasePath),b=f.observer.beginObservation();
    let token=appleJWT(claims(b.nonce,f.clock,overrides),header);
    if(alter==='signature'){const parts=token.split('.');parts[2]=(parts[2][0]==='A'?'B':'A')+parts[2].slice(1);token=parts.join('.');}
    await assert.rejects(f.observer.observeIdentity({observationID:b.observationID,identityToken:token}),e=>['unauthorized','fixtureUnauthorized'].includes(e.code));
    assert.deepEqual(snapshot(f.databasePath),before);
  });
});

test('identity observation enforces capacity without evicting live nonce',async t=>{
  const f=await observerFixture(t),before=snapshot(f.databasePath),pending=[];
  for(let i=0;i<128;i++)pending.push(f.observer.beginObservation());
  assert.throws(()=>f.observer.beginObservation(),e=>e.code==='fixtureUnavailable');
  const first=pending[0];await f.observer.observeIdentity({observationID:first.observationID,identityToken:appleJWT(claims(first.nonce,f.clock))});
  f.observer.beginObservation();f.clock.advance(61);assert.ok(f.observer.beginObservation().observationID);
  assert.deepEqual(snapshot(f.databasePath),before);
});

test('identity observation rechecks actual authority trust and generation after verifier await',async t=>{
  const mutations=[['generation',f=>f.advanceGeneration()],['environment',f=>authorityState(f.authority).config.environment='production'],
    ['key-object',f=>authorityState(f.authority).config.accountHMACKey=randomBytes(32)],['key-bytes',f=>authorityState(f.authority).config.accountHMACKey[0]^=255],
    ['clock',f=>authorityState(f.authority).config.clock={now:()=>f.clock.now()}],['fingerprint',f=>authorityState(f.authority).config.fingerprint='changed'],
    ['config-object',f=>authorityState(f.authority).config={...authorityState(f.authority).config}],['invalidate',f=>f.observer.invalidate()]];
  for(const [name,change]of mutations)await t.test(name,async st=>{
    let release,enter;const entered=new Promise(resolve=>enter=resolve),wait=new Promise(resolve=>release=resolve);
    const f=await observerFixture(st,{fetchJWKS:async()=>{enter();await wait;return structuredClone(appleJWKS);}}),before=snapshot(f.databasePath),b=f.observer.beginObservation();
    const outcome=f.observer.observeIdentity({observationID:b.observationID,identityToken:appleJWT(claims(b.nonce,f.clock))});
    const rejection=assert.rejects(outcome,e=>e.code==='fixtureUnauthorized');await entered;change(f);release();await rejection;
    assert.deepEqual(snapshot(f.databasePath),before);
  });
});

test('identity observation precedes original first-device HTTP authentication',async t=>{
  const {openM4AuthorityFixture}=await helper(),databasePath=newDB(),f=await openM4AuthorityFixture({databasePath});t.after(()=>f.close());
  const before=snapshot(databasePath),identity=await observe(f);assert.deepEqual(snapshot(databasePath),before);
  const {d,request}=await prepare(f),result=await raw(f,'/v1/auth/apple',request);
  assert.equal(result.status,200);assert.equal(result.data.receipt.body.result,'registered');
  assert.equal(result.data.context.accountID,identity.accountID);
  assertNoStoredSecrets(databasePath,['m4-fixture-primary-subject',request.identityToken,request.authorizationCode,result.data.credential.token,d.privateKey.export({format:'der',type:'pkcs8'}).subarray(-32)]);
  const account=rows(databasePath,'SELECT * FROM accounts')[0];assert.equal(account.active_phone_id,d.deviceID);assert.equal(account.activation_epoch,1);
  assert.equal(rows(databasePath,'SELECT public_key FROM devices WHERE device_id=?',d.deviceID)[0].public_key,d.devicePublicKey);
  const second=await prepare(f);const waiting=await raw(f,'/v1/auth/apple',second.request);assert.equal(waiting.data.receipt.body.result,'waitingMigration');
  assert.equal(rows(databasePath,'SELECT active_phone_id FROM accounts')[0].active_phone_id,d.deviceID);
  const afterAuth=snapshot(databasePath);assert.equal((await observe(f)).accountID,identity.accountID);assert.deepEqual(snapshot(databasePath),afterAuth);
});

import {request as httpRequest} from 'node:http';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {fileURLToPath} from 'node:url';
async function call(f,credential,d,path,body,{method='POST'}={}){
  const bytes=method==='GET'?Buffer.alloc(0):Buffer.from(canonicalJSON(body));
  const requestID=method==='GET'?path.split('/').at(-1):body.requestID;
  const proof=deviceAuth.makePoP(d.privateKey,{method,path,requestID,bodySHA256:sha256(bytes),sessionID:credential.sessionID,activationEpoch:credential.activationEpoch,keyID:d.keyID,nonce:randomUUID(),issuedAt:f.metadata.now});
  const response=await fetch(f.metadata.baseURL+path,{method,headers:{'content-type':'application/json',authorization:'Bearer '+credential.token,'x-device-pop':Buffer.from(canonicalJSON(proof)).toString('base64url')},body:method==='GET'?undefined:bytes});
  const text=await response.text();return {status:response.status,text,data:JSON.parse(text)};
}
async function recover(f,prepared){
  const {d,request}=prepared;
  const body={version:1,requestID:randomUUID(),authRequestID:request.requestID,deviceID:d.deviceID,keyID:d.keyID,devicePublicKey:d.devicePublicKey,nonce:randomUUID(),issuedAt:f.metadata.now};
  body.deviceProof=deviceAuth.signRecover(d.privateKey,body);return raw(f,'/v1/auth/recover',body);
}

test('fault beforeCommit rolls original first-auth back and recovery closes only its original tuple',async t=>{
  const {openM4AuthorityFixture}=await helper(),databasePath=newDB(),f=await openM4AuthorityFixture({databasePath});t.after(()=>f.close());
  const prepared=await prepare(f),before=snapshot(databasePath);
  f.setFault({name:'beforeCommit',value:true});const result=await raw(f,'/v1/auth/apple',prepared.request);assert.equal(result.status,503);
  f.setFault({name:'beforeCommit',value:false});assert.deepEqual(snapshot(databasePath),before);
  const recovery=await recover(f,prepared);assert.equal(recovery.data.status,'knownAbandoned');
  assert.equal((await raw(f,'/v1/auth/apple',prepared.request)).status,401);
  for(const table of ['accounts','devices','sessions','auth_records','requests','active_locks'])assert.equal(count(databasePath,table),0);
  assert.equal(rows(databasePath,'SELECT value FROM epoch_allocator')[0].value,0);
});

for(const fault of ['afterCommitResponseLost','dropResponseAfterOperation'])test('fault '+fault+' retains original session across reopen without consuming Apple again',async t=>{
  const {openM4AuthorityFixture}=await helper(),databasePath=newDB(),f=await openM4AuthorityFixture({databasePath});t.after(()=>f.close());
  const identity=await observe(f),prepared=await prepare(f);
  f.setFault({name:fault,value:fault==='afterCommitResponseLost'?true:'authenticate'});
  await assert.rejects(raw(f,'/v1/auth/apple',prepared.request));
  f.setFault({name:fault,value:fault==='afterCommitResponseLost'?false:null});
  const stored=rows(databasePath,'SELECT * FROM auth_records')[0];assert.equal(stored.auth_request_id,prepared.request.requestID);
  const first=await recover(f,prepared);assert.equal(first.status,200);assert.equal(first.data.credential.sessionID,stored.session_id);
  const repeat=await recover(f,prepared);assert.equal(repeat.data.credential.token===first.data.credential.token,true);
  assert.equal(count(databasePath,'sessions'),1);assert.equal(rows(databasePath,'SELECT consumed FROM challenges')[0].consumed,1);
  const acquire={version:1,requestID:randomUUID(),matchID:randomUUID(),recordingDeviceID:prepared.d.deviceID,activationEpoch:first.data.credential.activationEpoch};
  const held=await call(f,first.data.credential,prepared.d,'/v1/locks/acquire',acquire);assert.equal(held.data.body.result,'held');
  const pending=f.beginObservation(),metadata=f.metadata,before=snapshot(databasePath);await f.restart();
  assert.equal(f.metadata.publicKey,metadata.publicKey);assert.equal(f.metadata.keyID,metadata.keyID);assert.equal(f.metadata.namespace,metadata.namespace);
  assert.deepEqual(snapshot(databasePath),before);
  await assert.rejects(f.observeIdentity({observationID:pending.observationID,identityToken:f.issueApple({purpose:'observation',nonce:pending.nonce,identity:'primary'}).identityToken}),e=>e.code==='fixtureUnauthorized');
  assert.equal((await observe(f)).accountID,identity.accountID);
  const original=await call(f,first.data.credential,prepared.d,'/v1/requests/'+acquire.requestID,undefined,{method:'GET'});assert.equal(original.text,held.text);
  const recovered=await recover(f,prepared);assert.equal(recovered.data.credential.token===first.data.credential.token,true);
  assert.equal(count(databasePath,'accounts'),1);assert.equal(count(databasePath,'sessions'),1);assert.equal(count(databasePath,'active_locks'),1);
  assert.equal((await raw(f,'/v1/auth/apple',prepared.request)).status,401);
});

test('fault enum rejects unsupported controls without mutating SQL',async t=>{
  const {openM4AuthorityFixture}=await helper(),databasePath=newDB(),f=await openM4AuthorityFixture({databasePath});t.after(()=>f.close());const before=snapshot(databasePath);
  for(const input of [{name:'clock',value:0},{name:'beforeCommit',value:'true'},{name:'dropResponseAfterOperation',value:'authApple'},{name:'afterCommitResponseLost',value:true,extra:true}])assert.throws(()=>f.setFault(input),e=>e.code==='fixtureInvalidRequest');
  assert.deepEqual(snapshot(databasePath),before);
});

test('close joins actual HTTP handler tail after response destruction',async t=>{
  let release,entered;const wait=new Promise(resolve=>release=resolve),started=new Promise(resolve=>entered=resolve);
  const {openM4AuthorityFixture}=await helper(),f=await openM4AuthorityFixture({fetchJWKS:async()=>{entered();await wait;return structuredClone(appleJWKS);}});
  t.after(async()=>{release();await f.close();});const prepared=await prepare(f);
  const request=httpRequest(f.metadata.baseURL+'/v1/auth/apple',{method:'POST',headers:{'content-type':'application/json'}},response=>response.resume());request.on('error',()=>{});request.end(canonicalJSON(prepared.request));
  await started;const requestClosed=new Promise(resolve=>request.once('close',resolve));request.destroy();await requestClosed;
  let closed=false;const closing=f.close().then(()=>closed=true);await pause(25);assert.equal(closed,false,'DB must stay open until original HTTP handler finishes');release();await closing;assert.equal(closed,true);
});

test('close joins genuine observer verification and rejects its stale result',async t=>{
  let release,entered;const wait=new Promise(resolve=>release=resolve),started=new Promise(resolve=>entered=resolve);
  const {openM4AuthorityFixture}=await helper(),f=await openM4AuthorityFixture({fetchJWKS:async()=>{entered();await wait;return structuredClone(appleJWKS);}});
  t.after(async()=>{release();await f.close();});const b=f.beginObservation();
  const observing=f.observeIdentity({observationID:b.observationID,identityToken:f.issueApple({purpose:'observation',nonce:b.nonce,identity:'primary'}).identityToken});
  const rejected=assert.rejects(observing,e=>e.code==='fixtureUnauthorized');await started;
  let closed=false;const closing=f.close().then(()=>closed=true);await pause(25);assert.equal(closed,false,'observer tail is still owned');release();await rejected;await closing;
});

test('restart joins old observer before rebuilding same file and key mapping',async t=>{
  let release,entered;const wait=new Promise(resolve=>release=resolve),started=new Promise(resolve=>entered=resolve);let first=true;
  const {openM4AuthorityFixture}=await helper(),databasePath=newDB(),f=await openM4AuthorityFixture({databasePath,fetchJWKS:async()=>{if(first){first=false;entered();await wait;}return structuredClone(appleJWKS);}});
  t.after(async()=>{release();await f.close();});const b=f.beginObservation();
  const observing=f.observeIdentity({observationID:b.observationID,identityToken:f.issueApple({purpose:'observation',nonce:b.nonce,identity:'primary'}).identityToken});
  const rejected=assert.rejects(observing,e=>e.code==='fixtureUnauthorized');await started;const before=snapshot(databasePath),metadata=f.metadata;
  let restarted=false;const restarting=f.restart().then(()=>restarted=true);await pause(25);assert.equal(restarted,false);release();await rejected;await restarting;
  assert.deepEqual(snapshot(databasePath),before);assert.equal(f.metadata.publicKey,metadata.publicKey);assert.equal(f.metadata.namespace,metadata.namespace);assert.ok((await observe(f)).accountID);
});

test('revoker reuses existing controlled code exchange through original HTTP deletion',async t=>{
  const {openM4AuthorityFixture}=await helper(),databasePath=newDB(),f=await openM4AuthorityFixture({databasePath});t.after(()=>f.close());
  assert.deepEqual(await f.enableRevoker(),{enabled:true});assert.deepEqual(await f.enableRevoker(),{enabled:true});
  const prepared=await prepare(f),login=await raw(f,'/v1/auth/apple',prepared.request);assert.equal(login.status,200);
  const fresh=await prepare(f,prepared.d),reauth=await raw(f,'/v1/auth/apple',fresh.request);assert.equal(reauth.status,200);assert.ok(reauth.data.reauthenticationID);
  const deletion={version:1,requestID:randomUUID(),reauthenticationID:reauth.data.reauthenticationID,recoveryCapabilityDigest:sha256(randomBytes(32))};
  const result=await call(f,login.data.credential,prepared.d,'/v1/accounts/delete',deletion);assert.equal(result.status,200);assert.equal(result.data.body.result,'deleted');assert.equal(result.data.body.deletion.backend,'backendDeleted');
  assert.equal(count(databasePath,'accounts'),0);assert.equal(count(databasePath,'devices'),0);assert.equal(count(databasePath,'sessions'),0);
});

async function childFixture(t){
  const child=spawn(process.execPath,[fileURLToPath(helperURL)],{stdio:['pipe','pipe','pipe']});
  const messages=[],pending=new Map();let stderr='',readyResolve,readyReject;
  const ready=new Promise((resolve,reject)=>{readyResolve=resolve;readyReject=reject;});
  const exited=new Promise(resolve=>child.once('exit',(code,signal)=>{readyReject(Error('fixture exited before ready'));for(const {reject}of pending.values())reject(Error('fixture exited before reply'));pending.clear();resolve({code,signal});}));
  child.stderr.setEncoding('utf8');child.stderr.on('data',data=>stderr+=data);
  const lines=createInterface({input:child.stdout});lines.on('line',line=>{const value=JSON.parse(line);messages.push(value);if(value.type==='ready')readyResolve(value);else{const waiter=pending.get(value.requestID);if(waiter){pending.delete(value.requestID);waiter.resolve(value);}}});
  function line(text,requestID='unknown'){return new Promise((resolve,reject)=>{pending.set(requestID,{resolve,reject});child.stdin.write(text+'\n');});}
  const api={child,messages,exited,get stderr(){return stderr;},line,request(op,fields={},requestID=randomUUID()){return line(JSON.stringify({version:1,requestID,op,...fields}),requestID);}};
  t.after(async()=>{if(child.exitCode===null&&child.signalCode===null){await api.request('close').catch(()=>{});await exited;}lines.close();});
  api.ready=await ready;return api;
}

test('stdio exposes only metadata and strict correlated commands', {timeout:15000},async t=>{
  const c=await childFixture(t);assert.equal(c.ready.version,1);assert.equal(c.ready.environment,'development');assertNoSecrets(c.ready);
  const begin=await c.request('identity.begin');assert.equal(begin.ok,true);
  const appleID=randomUUID(),apple=await c.request('apple',{purpose:'observation',nonce:begin.result.nonce,identity:'primary'},appleID);assert.equal(apple.ok,true);assert.equal(typeof apple.result.identityToken,'string');assert.equal(typeof apple.result.authorizationCode,'string');
  const observation=await c.request('identity.observe',{observationID:begin.result.observationID,identityToken:apple.result.identityToken});assert.equal(observation.ok,true);assert.equal(observation.result.kind,'currentIdentity');
  const errorID=randomUUID();assert.equal((await c.request('clock',{},errorID)).error.code,'fixtureInvalidRequest');const duplicate=await c.request('identity.begin',{},errorID);assert.equal(duplicate.ok,false,'duplicate control requestID must reject');assert.equal(duplicate.error.code,'duplicateRequest');
  for(const reply of [await c.line('{bad-json'),await c.line('{"version":1,"requestID":"duplicate-json","op":"close","op":"identity.begin"}'),await c.line(JSON.stringify({version:1,requestID:'invalid id',op:'identity.begin'})),await c.line('X'.repeat(16385)),await c.request('identity.begin',{sql:'SECRET-SQL-BODY'})]){assert.equal(reply.ok,false);assert.equal(reply.error.code,'fixtureInvalidRequest');}
  assert.equal((await c.request('apple',{purpose:'observation',nonce:'bad',identity:'primary'})).error.code,'fixtureInvalidRequest');
  assert.equal((await c.request('fault',{name:'dropResponseAfterOperation',value:'authApple'})).error.code,'fixtureInvalidRequest');
  const restarted=await c.request('restart');assert.equal(restarted.ok,true);assert.equal(restarted.result.publicKey,c.ready.publicKey);assert.equal(restarted.result.namespace,c.ready.namespace);assertNoSecrets(restarted.result);
  assert.equal((await c.request('revoker')).ok,true);
  assert.equal((await c.request('close')).result.closed,true);assert.deepEqual(await c.exited,{code:0,signal:null});
  assert.equal(c.messages.filter(x=>x.type==='ready').length,1);
  for(const message of c.messages)if(message.requestID!==appleID)assertNoSecrets(message,['SECRET-SQL-BODY']);
  assert.equal(c.stderr.includes('SECRET-SQL-BODY'),false);for(const line of c.stderr.trim().split('\n').filter(Boolean)){const diagnostic=JSON.parse(line);assert.deepEqual(Object.keys(diagnostic).sort(),['code','operation']);}
});

test('stdio bounds unique control IDs and never replays token material',{timeout:15000},async t=>{
  const c=await childFixture(t);
  for(let i=0;i<4096;i++)assert.equal((await c.request('fault',{name:'beforeCommit',value:false},'control-'+i)).ok,true);
  assert.equal((await c.request('identity.begin',{},'overflow')).error.code,'fixtureUnavailable');
  assert.equal((await c.request('identity.begin',{},'control-0')).error.code,'duplicateRequest');
  c.child.stdin.end();assert.deepEqual(await c.exited,{code:0,signal:null});assert.equal(c.messages.filter(x=>x.type==='ready').length,1);
});

test('stdio EOF and SIGTERM close the owned HTTP listener',{timeout:15000},async t=>{
  for(const mode of ['EOF','SIGTERM'])await t.test(mode,async st=>{
    const c=await childFixture(st),base=c.ready.baseURL;
    if(mode==='EOF')c.child.stdin.end();else c.child.kill('SIGTERM');
    assert.deepEqual(await c.exited,{code:0,signal:null});await assert.rejects(fetch(base+'/v1/none'));
  });
});


test('restart preserves existing fault controls and close requested during restart waits',async t=>{
  const {openM4AuthorityFixture}=await helper(),databasePath=newDB(),f=await openM4AuthorityFixture({databasePath});t.after(()=>f.close());
  f.setFault({name:'beforeCommit',value:true});await f.restart();const d=device();
  const challenge={version:1,requestID:randomUUID(),deviceID:d.deviceID,devicePublicKey:d.devicePublicKey};
  assert.equal((await raw(f,'/v1/auth/challenges',challenge)).status,503);assert.equal(count(databasePath,'challenges'),0);
  f.setFault({name:'beforeCommit',value:false});assert.equal((await raw(f,'/v1/auth/challenges',challenge)).status,200);
  const restarting=f.restart(),closing=f.close();const metadata=await restarting;await closing;
  await assert.rejects(fetch(metadata.baseURL+'/v1/none'));assert.throws(()=>f.beginObservation(),e=>e.code==='fixtureClosed');
});

test('close joins pending existing revoker setup and closes the resulting listener',async t=>{
  const {openM4AuthorityFixture}=await helper(),f=await openM4AuthorityFixture();t.after(()=>f.close());
  const enabling=f.enableRevoker(),rejected=assert.rejects(enabling,e=>e.code==='fixtureClosed');
  const closing=f.close();await rejected;await closing;assert.throws(()=>f.beginObservation(),e=>e.code==='fixtureClosed');
});
