import {parentPort,workerData,threadId} from 'node:worker_threads';
import {createAuthority} from '../src/authority.mjs';
import {createDeviceAuth} from '../src/device-auth.mjs';
import {createDevelopmentAppleVerifier} from '../src/apple-verifier.mjs';
const config={...workerData.config,accountHMACKey:Buffer.from(workerData.config.accountHMACKey),tokenDerivationKey:Buffer.from(workerData.config.tokenDerivationKey),clock:{now:()=>workerData.now},faults:{}};
const authority=createAuthority(config),view=new Int32Array(workerData.barrier);
function barrier(){parentPort.postMessage({ready:true,threadId});Atomics.wait(view,0,0);}
const verifier=createDevelopmentAppleVerifier({audiences:['test.football'],clock:config.clock,fetchJWKS:async()=>workerData.jwks});
const auth=createDeviceAuth({authority,appleVerifier:{environment:'development',verify:async(...args)=>{const verified=await verifier.verify(...args);barrier();return verified;}}});
try {let result;if(workerData.mode==='authenticate')result=await auth.authenticate(workerData.request);else {barrier();result=auth.recover(workerData.request);}parentPort.postMessage({mode:workerData.mode,threadId,result});}
catch(error){parentPort.postMessage({mode:workerData.mode,threadId,error:{code:error.code??'unexpected',status:error.status??500}});}
finally{authority.close();}
