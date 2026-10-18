import {pathToFileURL} from 'node:url';
import {createInterface} from 'node:readline';
const root=process.argv[2];
const support=await import(pathToFileURL(root+'/backend/test/support.mjs'));
const f=await support.openHTTPFixture();
const login=await f.login();
let appleRevocationFixture;
const emit=value=>process.stdout.write(JSON.stringify(value)+String.fromCharCode(10));
emit({baseURL:f.baseURL,publicKey:f.f.receiptPublicKey,keyID:f.f.config.receiptKeyID,credential:login.credential,privateKey:login.d.privateKey.export({format:'der',type:'pkcs8'}).subarray(-32).toString('base64url'),now:f.f.clock.now()});
for await (const line of createInterface({input:process.stdin})) {
 try { const r=JSON.parse(line);
 if(r.op==='close'){emit({ok:true});await Promise.race([Promise.all([f.close(),appleRevocationFixture?.close()]),new Promise(resolve=>setTimeout(resolve,200))]);process.stdin.destroy();process.exit(0);}
 if(r.op==='fault'){f.f.faults.dropResponseAfterOperation=r.value;emit({ok:true});}
 else if(r.op==='revoker'){
   if(!appleRevocationFixture){const module=await import(pathToFileURL(root+'/backend/test/apple-revocation-support.mjs'));appleRevocationFixture=await module.startRevocationFixture({clock:f.f.clock});f.f.config.appleRevoker=appleRevocationFixture.revoker;}
   if(r.exchangeStatus!==undefined)appleRevocationFixture.controls.exchangeStatus=r.exchangeStatus;
   emit({ok:true});
 }
 else if(r.op==='lifecycleFault'){f.f.faults.lifecycleStep=r.value;emit({ok:true});}
 else if(r.op==='databaseFault'){f.f.faults.beforeCommit=r.value===true;emit({ok:true});}
 else if(r.op==='restart'){await f.restart();emit({baseURL:f.baseURL});}
 else if(r.op==='clock'){f.f.clock.set(r.now);emit({now:f.f.clock.now()});}
 else if(r.op==='watch'){
   const d=f.a.device(r.deviceID??'relay-watch'),challenge=await f.raw('/v1/auth/challenges',JSON.stringify({version:1,requestID:crypto.randomUUID(),deviceID:d.deviceID,devicePublicKey:d.devicePublicKey}));
   const request={version:1,requestID:crypto.randomUUID(),watchID:d.deviceID,watchPublicKey:d.devicePublicKey,challengeID:challenge.data.challengeID};
   request.deviceProof=support.challengeSignature(request,challenge.data.challenge,d.privateKey);
   const result=await f.call(login,'/v1/devices/watches',request);
   if(result.status!==200)throw Error();
   emit({credential:result.data.credential,privateKey:d.privateKey.export({format:'der',type:'pkcs8'}).subarray(-32).toString('base64url')});
 }
 else if(r.op==='apple'){const identityToken=support.appleJWT({iss:'https://appleid.apple.com',sub:r.subject??'fixture-subject-never-stored',aud:'test.football',nonce:r.nonce,iat:f.f.clock.now(),exp:f.f.clock.now()+300});let authorizationCode;if(appleRevocationFixture){authorizationCode='client-code-'+crypto.randomUUID();appleRevocationFixture.registerCode(authorizationCode,identityToken);}emit({identityToken,...(authorizationCode?{authorizationCode}:{})});}
 else if(r.op==='inspect'){emit({rows:f.f.inspect(r.sql)});}
 }catch{emit({error:'fixtureFailure'});}
}
