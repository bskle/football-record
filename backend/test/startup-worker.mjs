import {parentPort,workerData} from 'node:worker_threads';
import {generateKeyPairSync} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
// Delay persistence, not the acceptance assertion, to make first-use contention reproducible.
const prepare=DatabaseSync.prototype.prepare;
DatabaseSync.prototype.prepare=function(sql){if(sql.startsWith('INSERT OR IGNORE INTO metadata'))Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,40);return prepare.call(this,sql);};
import {createAuthority} from '../src/authority.mjs';
const {path,barrier,n}=workerData;
const key=generateKeyPairSync('ed25519').privateKey;
parentPort.postMessage({ready:true});Atomics.wait(new Int32Array(barrier),0,0);
try{const a=createAuthority({databasePath:path,accountHMACKey:Buffer.alloc(32,n),tokenDerivationKey:Buffer.alloc(32,n),receiptPrivateKey:key});a.close();parentPort.postMessage({accepted:true});}
catch(e){parentPort.postMessage({accepted:false,reason:e.message});}
