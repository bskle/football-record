import {pathToFileURL} from 'node:url';
import {createInterface} from 'node:readline';
const root=process.argv[2];
const support=await import(pathToFileURL(root+'/backend/test/support.mjs'));
const f=await support.openHTTPFixture();
const login=await f.login();
const emit=value=>process.stdout.write(JSON.stringify(value)+String.fromCharCode(10));
emit({baseURL:f.baseURL,publicKey:f.f.receiptPublicKey,keyID:f.f.config.receiptKeyID,credential:login.credential,privateKey:login.d.privateKey.export({format:'der',type:'pkcs8'}).subarray(-32).toString('base64url'),now:f.f.clock.now()});
for await (const line of createInterface({input:process.stdin})) {
 try { const r=JSON.parse(line);
 if(r.op==='close'){emit({ok:true});await Promise.race([f.close(),new Promise(resolve=>setTimeout(resolve,200))]);process.stdin.destroy();process.exit(0);}
 if(r.op==='fault'){f.f.faults.dropResponseAfterOperation=r.value;emit({ok:true});}
 else if(r.op==='restart'){await f.restart();emit({baseURL:f.baseURL});}
 else if(r.op==='clock'){f.f.clock.set(r.now);emit({now:f.f.clock.now()});}
 else if(r.op==='apple'){emit({identityToken:support.appleJWT({iss:'https://appleid.apple.com',sub:r.subject??'fixture-subject-never-stored',aud:'test.football',nonce:r.nonce,iat:f.f.clock.now(),exp:f.f.clock.now()+300})});}
 else if(r.op==='inspect'){emit({rows:f.f.inspect(r.sql)});}
 }catch{emit({error:'fixtureFailure'});}
}
