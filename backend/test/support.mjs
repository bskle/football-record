import {mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {generateKeyPairSync,randomBytes,randomUUID,sign} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {Worker} from 'node:worker_threads';
import {rawPublicKey,sha256,canonicalJSON} from '../src/receipt.mjs';
export function tempDB(){return join(mkdtempSync(join(tmpdir(),'football-authority-')),'authority.sqlite');}
export function fixtureClock(start=1800000000){let now=start;return {now:()=>now,advance:n=>{now+=n;},set:n=>{now=n;}};}
export async function startFixtureAuthority(options={}){
  const {createAuthority,authorityState}=await import('../src/authority.mjs');
  const clock=options.clock??fixtureClock(),faults=options.faults??{};
  const pair=generateKeyPairSync('ed25519'),device=generateKeyPairSync('ed25519');
  const publicKey=rawPublicKey(device.privateKey),keyID=sha256(publicKey);
  const config={databasePath:options.databasePath??tempDB(),accountHMACKey:randomBytes(32),tokenDerivationKey:randomBytes(32),receiptPrivateKey:pair.privateKey,clock,faults,environment:'development'};
  let authority=createAuthority(config);
  const context={accountID:'fixture-account',deviceID:'fixture-phone',keyID,activationEpoch:1};
  const inspect=sql=>{const d=new DatabaseSync(config.databasePath);try{return d.prepare(sql).all();}finally{d.close();}};
  const d=new DatabaseSync(config.databasePath);d.exec('BEGIN IMMEDIATE');
  d.prepare('INSERT INTO accounts(account_id,cloud_space_id,active_phone_id,activation_epoch) VALUES(?,?,?,?)').run(context.accountID,'fixture-cloud',context.deviceID,1);
  d.prepare('INSERT INTO devices VALUES(?,?,?,?,?,?)').run(context.deviceID,context.accountID,keyID,publicKey,'phone',1);
  d.prepare('UPDATE epoch_allocator SET value=1 WHERE id=1').run();d.exec('COMMIT');d.close();
  const acquire=id=>({version:1,requestID:id,matchID:'match-'+id,recordingDeviceID:context.deviceID,activationEpoch:context.activationEpoch});
  const f={get config(){return authorityState(authority).config;},clock,faults,context,device,publicKey,receiptPublicKey:rawPublicKey(pair.privateKey),inspect,acquire,get authority(){return authority;},client:{async liveStatus(b){return authority.liveStatus(context,{version:1,requestID:randomUUID(),acquireRequestID:b.requestID,matchID:b.matchID,lockID:b.lockID,recordingDeviceID:b.recordingDeviceID,activationEpoch:b.activationEpoch,nonce:randomUUID()}).body;}},async restart(){const current=authorityState(authority).config;authority.close();authority=createAuthority(current);},async close(){authority.close();},async raceWorkers(ids){
    const barrier=new SharedArrayBuffer(4),view=new Int32Array(barrier);
    const workers=ids.map(id=>new Worker(new URL('./lock-worker.mjs',import.meta.url),{workerData:{config:{...config,clock:undefined,faults:{},receiptPrivateKey:pair.privateKey.export({type:'pkcs8',format:'pem'})},now:clock.now(),context,request:acquire(id),barrier}}));
    let ready=0;const promises=workers.map(w=>new Promise((resolve,reject)=>{w.on('error',reject);w.on('message',m=>{if(m.ready){ready++;if(ready===workers.length){Atomics.store(view,0,1);Atomics.notify(view,0);}}else if(m.error)reject(new Error(JSON.stringify(m.error)));else resolve(m.result);});}));
    const results=await Promise.all(promises);await Promise.all(workers.map(w=>w.terminate()));return results;
  }};return f;
}

const rsa=generateKeyPairSync('rsa',{modulusLength:2048});
export const appleJWKS={keys:[{...rsa.publicKey.export({format:'jwk'}),kid:'fixture-apple',alg:'RS256',use:'sig'}]};
export function appleJWT(claims,header={alg:'RS256',kid:'fixture-apple'}){
  const input=Buffer.from(JSON.stringify(header)).toString('base64url')+'.'+Buffer.from(JSON.stringify(claims)).toString('base64url');
  return input+'.'+sign('RSA-SHA256',Buffer.from(input),rsa.privateKey).toString('base64url');
}
export function challengeSignature(request,challenge,privateKey){
  const value={...request,challengeSHA256:sha256(challenge)};delete value.deviceProof;
  return sign(null,Buffer.from('football-record.device.challenge.v1\n'+canonicalJSON(value)),privateKey).toString('base64url');
}
export async function authSetup(f,options={}){
  const {createDevelopmentAppleVerifier}=await import('../src/apple-verifier.mjs');
  const {createDeviceAuth,makePoP}=await import('../src/device-auth.mjs');
  const verifier=createDevelopmentAppleVerifier({audiences:['test.football'],clock:f.clock,fetchJWKS:options.fetchJWKS??(async()=>structuredClone(appleJWKS))});
  const auth=createDeviceAuth({authority:f.authority,appleVerifier:verifier});
  function device(deviceID=randomUUID()){const keys=generateKeyPairSync('ed25519');return {deviceID,privateKey:keys.privateKey,devicePublicKey:rawPublicKey(keys.privateKey),keyID:sha256(rawPublicKey(keys.privateKey))};}
  function request(d,overrides={}){
    const challenge=auth.challenge({version:1,requestID:randomUUID(),deviceID:d.deviceID,devicePublicKey:d.devicePublicKey});
    const identityToken=appleJWT({iss:'https://appleid.apple.com',sub:'fixture-subject-never-stored',aud:'test.football',nonce:sha256(challenge.challenge),iat:f.clock.now(),exp:f.clock.now()+300,...overrides.claims},overrides.header);
    const r={version:1,requestID:randomUUID(),challengeID:challenge.challengeID,identityToken,authorizationCode:'transient-code-never-stored',deviceID:d.deviceID,devicePublicKey:d.devicePublicKey,cloudSpaceID:'fixture-cloud',...overrides.body};
    r.deviceProof=challengeSignature(r,challenge.challenge,d.privateKey);return {r,challenge};
  }
  async function login(d=device(),overrides={}){const {r}=request(d,overrides);const result=await auth.authenticate(r);return {d,r,result,credential:result.credential,context:result.context};}
  function proof(login,{method='POST',path='/v1/locks/acquire',requestID='pop-request',bodyBytes=Buffer.from('{}'),nonce=randomUUID(),issuedAt=f.clock.now()}={}){
    return makePoP(login.d.privateKey,{method,path,requestID,bodySHA256:sha256(bodyBytes),sessionID:login.credential.sessionID,activationEpoch:login.credential.activationEpoch,keyID:login.d.keyID,nonce,issuedAt});
  }
  return {auth,verifier,device,request,login,proof};
}
