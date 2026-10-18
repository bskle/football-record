import {mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {generateKeyPairSync,randomBytes,randomUUID} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {Worker} from 'node:worker_threads';
import {rawPublicKey,sha256} from '../src/receipt.mjs';
export function tempDB(){return join(mkdtempSync(join(tmpdir(),'football-authority-')),'authority.sqlite');}
export function fixtureClock(start=1800000000){let now=start;return {now:()=>now,advance:n=>{now+=n;},set:n=>{now=n;}};}
export async function startFixtureAuthority(options={}){
  const {createAuthority}=await import('../src/authority.mjs');
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
  const f={config,clock,faults,context,device,publicKey,receiptPublicKey:rawPublicKey(pair.privateKey),inspect,acquire,get authority(){return authority;},client:{async liveStatus(b){return authority.liveStatus(context,{version:1,requestID:randomUUID(),acquireRequestID:b.requestID,matchID:b.matchID,lockID:b.lockID,recordingDeviceID:b.recordingDeviceID,activationEpoch:b.activationEpoch,nonce:randomUUID()}).body;}},async restart(){authority.close();authority=createAuthority(config);},async close(){authority.close();},async raceWorkers(ids){
    const barrier=new SharedArrayBuffer(4),view=new Int32Array(barrier);
    const workers=ids.map(id=>new Worker(new URL('./lock-worker.mjs',import.meta.url),{workerData:{config:{...config,clock:undefined,faults:{},receiptPrivateKey:pair.privateKey.export({type:'pkcs8',format:'pem'})},now:clock.now(),context,request:acquire(id),barrier}}));
    let ready=0;const promises=workers.map(w=>new Promise((resolve,reject)=>{w.on('error',reject);w.on('message',m=>{if(m.ready){ready++;if(ready===workers.length){Atomics.store(view,0,1);Atomics.notify(view,0);}}else if(m.error)reject(new Error(JSON.stringify(m.error)));else resolve(m.result);});}));
    const results=await Promise.all(promises);await Promise.all(workers.map(w=>w.terminate()));return results;
  }};return f;
}
