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
