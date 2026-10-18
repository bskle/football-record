// Explicit local development rehearsal; never accepts user DB/credentials/Apple endpoints.
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import {createLocalTLSProxy,runContractSmoke} from './tls-smoke.mjs';
export async function runTLSDrill(){
 const {operationalFixture}=await import('../test/support/operational-fixture.mjs'),{localCertificate}=await import('../test/support/operational-tls.mjs');
 const sourceVersion=execFileSync('git',['-C',fileURLToPath(new URL('../../',import.meta.url)),'rev-parse','HEAD'],{stdio:['ignore','pipe','ignore']}).toString('utf8').trim(),f=await operationalFixture({http:true});let server;
 try{const cert=localCertificate();server=createLocalTLSProxy({...cert,upstreamURL:f.h.baseURL,sourceVersion});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));return await runContractSmoke({url:'https://localhost:'+server.address().port,caFile:cert.certFile,expectedVersion:sourceVersion});}
 finally{if(server){server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}await f.close();}
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){try{process.stdout.write(JSON.stringify(await runTLSDrill())+'\n');}catch{process.stdout.write(JSON.stringify({ok:false,code:'unavailable'})+'\n');process.exitCode=1;}}
