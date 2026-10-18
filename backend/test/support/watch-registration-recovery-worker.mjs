import {workerData,parentPort,threadId} from 'node:worker_threads';
import {createAuthority} from '../../src/authority.mjs';
import {createDeviceAuth} from '../../src/device-auth.mjs';
import {createDevelopmentAppleVerifier} from '../../src/apple-verifier.mjs';
import {canonicalJSON} from '../../src/receipt.mjs';
const config={...workerData.config,accountHMACKey:Buffer.from(workerData.config.accountHMACKey),tokenDerivationKey:Buffer.from(workerData.config.tokenDerivationKey),clock:{now:()=>workerData.now},faults:{}},authority=createAuthority(config);
createDeviceAuth({authority,appleVerifier:createDevelopmentAppleVerifier({audiences:['test.football'],clock:config.clock,fetchJWKS:async()=>({keys:[]})})});
parentPort.postMessage({ready:true,threadId});Atomics.wait(new Int32Array(workerData.barrier),0,0);
try{const result=authority[workerData.mode](workerData.context,workerData.request);parentPort.postMessage({threadId,mode:workerData.mode,result,bytes:canonicalJSON(result)});}catch(e){parentPort.postMessage({threadId,mode:workerData.mode,error:e.code??'unexpected'});}finally{authority.close();}
