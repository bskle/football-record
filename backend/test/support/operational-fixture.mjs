import {writeFileSync,chmodSync,existsSync} from 'node:fs';
import {dirname,join} from 'node:path';
import {startFixtureAuthority,openHTTPFixture} from '../support.mjs';
export async function operationalFixture({http=false}={}){
 const h=http?await openHTTPFixture():undefined,f=h?.f??await startFixtureAuthority(),directory=dirname(f.config.databasePath);
 const paths={accountHMACKeyFile:join(directory,'account.key'),tokenDerivationKeyFile:join(directory,'token.key'),receiptPrivateKeyFile:join(directory,'receipt.pem')};
 writeFileSync(paths.accountHMACKeyFile,f.config.accountHMACKey,{mode:0o600});writeFileSync(paths.tokenDerivationKeyFile,f.config.tokenDerivationKey,{mode:0o600});writeFileSync(paths.receiptPrivateKeyFile,f.config.receiptPrivateKey.export({type:'pkcs8',format:'pem'}),{mode:0o600});
 const config={databasePath:f.config.databasePath,environment:'development',...paths},configPath=join(directory,'ops.json');writeFileSync(configPath,JSON.stringify(config),{mode:0o600});
 const modes=()=>{for(const file of [f.config.databasePath,f.config.databasePath+'-wal',f.config.databasePath+'-shm'])if(existsSync(file))chmodSync(file,0o600);};modes();
 return {f,h,directory,paths,configPath,config,modes,close:()=>h?h.close():f.close()};
}

import {randomUUID,randomBytes} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {canonicalJSON,sha256,verifySigned} from '../../src/receipt.mjs';
import {createAuthority} from '../../src/authority.mjs';
import {createDeviceAuth,signRecover,makePoP} from '../../src/device-auth.mjs';
import {createHTTPServer} from '../../src/http.mjs';
import {createDevelopmentAppleVerifier} from '../../src/apple-verifier.mjs';
import {appleJWT,appleJWKS,challengeSignature} from '../support.mjs';
const request=fields=>({version:1,requestID:randomUUID(),...fields});
export async function seedOperationalState(f){
 const h=f.h,phone=await h.login(),acquire=request({matchID:'ops-match',recordingDeviceID:phone.d.deviceID,activationEpoch:phone.credential.activationEpoch}),held=await h.call(phone,'/v1/locks/acquire',acquire);
 const d=h.a.device(),challenge=(await h.raw('/v1/auth/challenges',canonicalJSON(request({deviceID:d.deviceID,devicePublicKey:d.devicePublicKey})))).data;
 const auth=request({challengeID:challenge.challengeID,identityToken:appleJWT({iss:'https://appleid.apple.com',sub:'ops-absent-subject',aud:'test.football',nonce:sha256(challenge.challenge),iat:h.f.clock.now(),exp:h.f.clock.now()+300}),authorizationCode:'ops-code',deviceID:d.deviceID,devicePublicKey:d.devicePublicKey,cloudSpaceID:'fixture-cloud'});auth.deviceProof=challengeSignature(auth,challenge.challenge,d.privateKey);
 const recover=()=>{const r=request({authRequestID:auth.requestID,deviceID:d.deviceID,keyID:d.keyID,devicePublicKey:d.devicePublicKey,nonce:randomUUID(),issuedAt:h.f.clock.now()});r.deviceProof=signRecover(d.privateKey,r);return r;};
 if((await h.raw('/v1/auth/recover',canonicalJSON(recover()))).data.status!=='knownAbandoned')throw Error('fixture');
 const deletedPhone=await h.login(undefined,{subject:'ops-deleted-subject'}),fresh=await h.login(deletedPhone.d,{subject:'ops-deleted-subject'}),capability=randomBytes(32).toString('base64url'),deletion=request({reauthenticationID:fresh.result.reauthenticationID,recoveryCapabilityDigest:sha256(capability)});
 h.f.config.appleRevoker=async()=>({revoked:true});const deleted=await h.call(deletedPhone,'/v1/accounts/delete',deletion);if(deleted.status!==200)throw Error('fixture');
 f.modes();return {phone,acquire,held:held.data,heldText:held.text,auth,recover,deleted:deleted.data,deletion,capability,epoch:h.f.inspect('SELECT value FROM epoch_allocator')[0].value,publicKey:h.f.receiptPublicKey};
}
export async function restoredHTTP(configPath,clock){
 const {readConfiguration}=await import('../../ops/config.mjs'),config={...readConfiguration(configPath),clock},authority=createAuthority(config),verifier=createDevelopmentAppleVerifier({audiences:['test.football'],clock,fetchJWKS:async()=>appleJWKS}),auth=createDeviceAuth({authority,appleVerifier:verifier}),server=createHTTPServer({authority,appleVerifier:verifier,deviceAuth:auth});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 async function raw(path,body,{method='POST',headers={}}={}){const r=await fetch('http://127.0.0.1:'+server.address().port+path,{method,headers:{'content-type':'application/json',...headers},body:method==='GET'?undefined:canonicalJSON(body)}),text=await r.text();return {status:r.status,text,data:JSON.parse(text)};}
 const call=(login,path,body,{method='POST'}={})=>{const bytes=method==='GET'?Buffer.alloc(0):Buffer.from(canonicalJSON(body)),proof=makePoP(login.d.privateKey,{method,path,requestID:method==='GET'?path.split('/').at(-1):body.requestID,bodySHA256:sha256(bytes),sessionID:login.credential.sessionID,activationEpoch:login.credential.activationEpoch,keyID:login.credential.keyID,nonce:randomUUID(),issuedAt:clock.now()});return raw(path,body,{method,headers:{authorization:'Bearer '+login.credential.token,'x-device-pop':Buffer.from(canonicalJSON(proof)).toString('base64url')}});};
 return {raw,call,config,inspect(sql){const d=new DatabaseSync(config.databasePath);try{return d.prepare(sql).all();}finally{d.close();}},close:async()=>{await new Promise(resolve=>server.close(resolve));authority.close();}};
}
export async function verifyOperationalRestore(configPath,state,clock){
 const r=await restoredHTTP(configPath,clock);try{
  const original=await r.call(state.phone,'/v1/requests/'+state.acquire.requestID,undefined,{method:'GET'});if(original.text!==state.heldText||!verifySigned(state.publicKey,original.data))throw Error('receipt');
  const competing=await r.call(state.phone,'/v1/locks/acquire',{...state.acquire,requestID:randomUUID(),matchID:'other-ops-match'});if(competing.data.body.result!=='originalMatch'||competing.data.body.lockID!==state.held.body.lockID||r.inspect('SELECT count(*) AS n FROM active_locks')[0].n!==1)throw Error('lock');
  const {generateKeyPairSync}=await import('node:crypto'),{rawPublicKey}=await import('../../src/receipt.mjs'),pair=generateKeyPairSync('ed25519'),deviceID=randomUUID(),devicePublicKey=rawPublicKey(pair.privateKey),c=(await r.raw('/v1/auth/challenges',request({deviceID,devicePublicKey}))).data;
  const login=request({challengeID:c.challengeID,identityToken:appleJWT({iss:'https://appleid.apple.com',sub:'ops-next-epoch',aud:'test.football',nonce:sha256(c.challenge),iat:clock.now(),exp:clock.now()+300}),authorizationCode:'ops-next-code',deviceID,devicePublicKey,cloudSpaceID:'fixture-cloud'});login.deviceProof=challengeSignature(login,c.challenge,pair.privateKey);const next=await r.raw('/v1/auth/apple',login);if(next.data.credential?.activationEpoch!==state.epoch+1)throw Error('epoch');
  if((await r.raw('/v1/auth/recover',state.recover())).data.status!=='knownAbandoned'||(await r.raw('/v1/auth/apple',state.auth)).status!==401)throw Error('fence');
  const deleted=await r.raw('/v1/accounts/delete-status',request({deleteRequestID:state.deletion.requestID,recoveryCapability:state.capability}));if(deleted.data.status!=='backendDeleted'||canonicalJSON(deleted.data.receipt)!==canonicalJSON(state.deleted))throw Error('delete');
  if(r.config.appleRevoker!==undefined)throw Error('revoker');return {ok:true,code:'restoreDrillComplete',checks:6};
 }finally{await r.close();}
}
