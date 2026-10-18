import {parentPort,workerData} from 'node:worker_threads';
import {createAuthority} from '../src/authority.mjs';
const {config,context,request,barrier,now}=workerData;
config.accountHMACKey=Buffer.from(config.accountHMACKey);config.tokenDerivationKey=Buffer.from(config.tokenDerivationKey);config.clock={now:()=>now};
const authority=createAuthority(config);
parentPort.postMessage({ready:true});Atomics.wait(new Int32Array(barrier),0,0);
try{let result;for(let i=0;i<3;i++){try{result=authority.acquire(context,request);break;}catch(e){if(e.code!=='unavailable'||i===2)throw e;}}parentPort.postMessage({result});}
catch(e){parentPort.postMessage({error:{code:e.code,message:e.message}});}finally{authority.close();}
