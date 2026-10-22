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
  const account=rows(databasePath,'SELECT * FROM accounts')[0];assert.equal(account.active_phone_id,d.deviceID);assert.equal(account.activation_epoch,1);
  assert.equal(rows(databasePath,'SELECT public_key FROM devices WHERE device_id=?',d.deviceID)[0].public_key,d.devicePublicKey);
  const second=await prepare(f);const waiting=await raw(f,'/v1/auth/apple',second.request);assert.equal(waiting.data.receipt.body.result,'waitingMigration');
  assert.equal(rows(databasePath,'SELECT active_phone_id FROM accounts')[0].active_phone_id,d.deviceID);
  const afterAuth=snapshot(databasePath);assert.equal((await observe(f)).accountID,identity.accountID);assert.deepEqual(snapshot(databasePath),afterAuth);
});
