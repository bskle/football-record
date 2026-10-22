import {createDeletionReauthentication,assertDeletionControlPurpose,assertDeletionControlNonceBudget} from './deletion-reauth.mjs';
import {isAppleVerifier,isVerifiedApple} from './apple-verifier.mjs';
import {routes,validatePayload} from './codec.mjs';
import {createHmac,randomBytes,randomUUID,sign,verify,timingSafeEqual} from 'node:crypto';
import {authorityState} from './authority.mjs';
import {canonicalJSON,sha256,edPublicKey,decodeBase64URL,makeReceipt} from './receipt.mjs';
import {transaction,fail,nextEpoch} from './database.mjs';
const input=(domain,body)=>Buffer.from(domain+'\n'+canonicalJSON(body));
export function makePoP(privateKey,fields){return {keyID:fields.keyID,nonce:fields.nonce,issuedAt:fields.issuedAt,signature:sign(null,input('football-record.device.pop.v1',fields),privateKey).toString('base64url')};}
export function signRecover(privateKey,request){const r={...request};delete r.deviceProof;return sign(null,input('football-record.device.auth-recover.v1',r),privateKey).toString('base64url');}
function signatureOK(key,domain,body,signature){try{return verify(null,input(domain,body),edPublicKey(key),decodeBase64URL(signature,64));}catch{return false;}}
export function createDeviceAuth({authority,appleVerifier}){
 const state=authorityState(authority);if(!state)throw Error('authority required');const {db,config,validate,stored,persist}=state;
 if(appleVerifier?.environment!==config.environment||(config.environment==='production'&&!isAppleVerifier(appleVerifier,'production')))throw Error('authority and verifier environment mismatch');
 function recoveryHash(domain,values){return createHmac('sha256',config.tokenDerivationKey).update(domain+'\n'+canonicalJSON(values)).digest('hex');}
 const absenceKey=(authRequestID,deviceID,keyID)=>recoveryHash('football-record.auth-absence.v1',[authRequestID,deviceID,keyID]);
 const watchFenceKey=(ctx,r)=>recoveryHash('football-record.watch-registration-closed.v1',[ctx.accountID,r.requestID,sha256(canonicalJSON(r)),r.watchID,sha256(r.watchPublicKey)]);
 function checkWatchFence(ctx,r){if(db.prepare('SELECT 1 FROM auth_absence_fences WHERE fence_id=?').get(watchFenceKey(ctx,r)))fail('unauthorized',401);}
 function tokenFor(s){const claims={sessionID:s.session_id,accountID:s.account_id,deviceID:s.device_id,keyID:s.key_id,activationEpoch:s.activation_epoch,expiresAt:s.expires_at};return createHmac('sha256',config.tokenDerivationKey).update('football-record.session.v1\n'+canonicalJSON(claims)).digest('base64url');}
 function credential(s){return {token:tokenFor(s),sessionID:s.session_id,accountID:s.account_id,deviceID:s.device_id,keyID:s.key_id,activationEpoch:s.activation_epoch,expiresAt:s.expires_at};}
 function session(ctx){const s={session_id:randomUUID(),account_id:ctx.accountID,device_id:ctx.deviceID,key_id:ctx.keyID,activation_epoch:ctx.activationEpoch,expires_at:config.clock.now()+2592000};db.prepare('INSERT INTO sessions VALUES(?,?,?,?,?,?,?,0)').run(s.session_id,s.account_id,s.device_id,s.key_id,s.activation_epoch,s.expires_at,sha256(tokenFor(s)));return s;}
 function consumeNonce(sessionID,nonce){assertDeletionControlNonceBudget(state,sessionID,nonce);if(db.prepare('SELECT 1 FROM nonces WHERE session_id=? AND nonce=?').get(sessionID,nonce))fail('unauthorized',401);db.prepare('INSERT INTO nonces VALUES(?,?)').run(sessionID,nonce);}
 function challenge(r){validatePayload('challenge',r);return transaction(db,config,()=>{
   try{edPublicKey(r.devicePublicKey);}catch{fail('invalidPayload',422);}
   if(db.prepare("SELECT 1 FROM requests WHERE request_id=? AND operation LIKE 'deleteControl%'").get(r.requestID))fail('idempotencyConflict');
   const digest=sha256(canonicalJSON(r)),prior=db.prepare('SELECT * FROM challenge_requests WHERE request_id=?').get(r.requestID);
   let c;if(prior){if(prior.request_digest!==digest)fail('idempotencyConflict');c=db.prepare('SELECT * FROM challenges WHERE challenge_id=?').get(prior.challenge_id);}
   else{c={challenge_id:randomUUID(),device_id:r.deviceID,key_fingerprint:sha256(r.devicePublicKey),expires_at:config.clock.now()+300,consumed:0};}
   const claims={challengeID:c.challenge_id,requestID:r.requestID,deviceID:c.device_id,keyFingerprint:c.key_fingerprint,expiresAt:c.expires_at};
   const secret=createHmac('sha256',config.tokenDerivationKey).update('football-record.challenge.v1\n'+canonicalJSON(claims)).digest('base64url');
   if(!prior){db.prepare('INSERT INTO challenges VALUES(?,?,?,?,?,0)').run(c.challenge_id,sha256(secret),r.deviceID,c.key_fingerprint,c.expires_at);db.prepare('INSERT INTO challenge_requests VALUES(?,?,?)').run(r.requestID,digest,c.challenge_id);}
   const response={version:1,requestID:r.requestID,challengeID:c.challenge_id,expiresAt:c.expires_at};
   if(c.consumed)return {...response,status:'consumed'};if(c.expires_at<config.clock.now())return {...response,status:'expired'};return {...response,challenge:secret};
 });}
 function checkChallenge(r,publicKey,deviceID,closing=false){if(db.prepare("SELECT 1 FROM challenge_requests c JOIN requests r ON c.request_id=r.request_id WHERE c.challenge_id=? AND r.operation LIKE 'deleteControl%'").get(r.challengeID))fail('unauthorized',401);const c=db.prepare('SELECT * FROM challenges WHERE challenge_id=?').get(r.challengeID);if(!c||(!closing&&(c.consumed||c.expires_at<config.clock.now()))||c.device_id!==deviceID||c.key_fingerprint!==sha256(publicKey))fail('unauthorized',401);const proof={...r,challengeSHA256:c.challenge_hash};delete proof.deviceProof;if(!signatureOK(publicKey,'football-record.device.challenge.v1',proof,r.deviceProof))fail('unauthorized',401);return c;}
 function output(record,s){return {...JSON.parse(Buffer.from(record)),credential:credential(s),context:{accountID:s.account_id,deviceID:s.device_id,keyID:s.key_id,activationEpoch:s.activation_epoch}};}
 async function authenticate(r){
   validatePayload('authApple',r);
   const c=checkChallenge(r,r.devicePublicKey,r.deviceID);
   const verified=await appleVerifier.verify(r.identityToken,c.challenge_hash);
   if(config.environment==='production'&&(!isVerifiedApple(verified,'production')||verified.environment!=='production'))fail('unauthorized',401);
   state.pruneReauthMaterial();let createdReauthenticationID;
   try{return transaction(db,config,()=>{
    if(db.prepare('SELECT 1 FROM auth_absence_fences WHERE fence_id=?').get(absenceKey(r.requestID,r.deviceID,sha256(r.devicePublicKey))))fail('unauthorized',401);
    checkChallenge(r,r.devicePublicKey,r.deviceID);
    const accountID=createHmac('sha256',config.accountHMACKey).update(verified.issuer+'\n'+verified.subject).digest('hex');
    let a=db.prepare('SELECT * FROM accounts WHERE account_id=?').get(accountID);
    const prior=db.prepare('SELECT * FROM devices WHERE device_id=?').get(r.deviceID);
    if(prior&&(prior.account_id!==accountID||prior.public_key!==r.devicePublicKey||prior.role==='watch'))fail('unauthorized',401);
    if(a&&a.cloud_space_id!==r.cloudSpaceID)fail('cloudIdentityMismatch',403);
    if(!a){const epoch=nextEpoch(db);db.prepare('INSERT INTO accounts(account_id,cloud_space_id,active_phone_id,activation_epoch) VALUES(?,?,?,?)').run(accountID,r.cloudSpaceID,r.deviceID,epoch);a=db.prepare('SELECT * FROM accounts WHERE account_id=?').get(accountID);}
    const role=a.active_phone_id===r.deviceID?'phone':'waiting',keyID=sha256(r.devicePublicKey);
    if(!prior)db.prepare('INSERT INTO devices VALUES(?,?,?,?,?,?)').run(r.deviceID,accountID,keyID,r.devicePublicKey,role,a.activation_epoch);
    else db.prepare('UPDATE devices SET role=?,activation_epoch=? WHERE device_id=? AND account_id=? AND public_key=?').run(role,a.activation_epoch,r.deviceID,accountID,r.devicePublicKey);
    const ctx={accountID,deviceID:r.deviceID,keyID,activationEpoch:a.activation_epoch};
    const first=stored(ctx,r,'authApple');if(first)fail('unauthorized',401);
    db.prepare('UPDATE challenges SET consumed=1 WHERE challenge_id=?').run(r.challengeID);
    const s=session(ctx),result={receipt:makeReceipt(config,ctx,r,'authApple',role==='phone'?'registered':'waitingMigration'),sessionClaims:{sessionID:s.session_id,expiresAt:s.expires_at}};
    if(prior){const id=randomUUID();db.prepare('INSERT INTO reauthentications VALUES(?,?,?,?,?,?,0)').run(id,accountID,r.deviceID,keyID,verified.issuedAt,verified.issuedAt+300);result.reauthenticationID=id;createdReauthenticationID=id;state.storeReauthMaterial(id,{authorizationCode:r.authorizationCode,expectedApple:verified,binding:Object.freeze({...ctx,reauthenticationID:id}),expiresAt:verified.issuedAt+300});
      db.prepare("UPDATE deletions SET reauthentication_id=? WHERE account_id=? AND device_id=? AND state IN ('requested','lockReconciled')").run(id,accountID,r.deviceID);}
    const bytes=Buffer.from(canonicalJSON(result));persist(ctx,r,'authApple',result);db.prepare('INSERT INTO auth_records VALUES(?,?,?,?,?,?,?)').run(r.requestID,r.deviceID,accountID,sha256(canonicalJSON(r)),r.devicePublicKey,s.session_id,bytes);
    return output(bytes,s);
   });}catch(error){if(createdReauthenticationID&&!db.prepare('SELECT 1 FROM reauthentications WHERE reauthentication_id=?').get(createdReauthenticationID))state.dropReauthMaterial(createdReauthenticationID);throw error;}
 }
 function recover(r){validatePayload('authRecover',r);return transaction(db,config,()=>{
   const row=db.prepare('SELECT * FROM auth_records WHERE auth_request_id=? AND device_id=?').get(r.authRequestID,r.deviceID);
   if(row){let value;try{value=JSON.parse(Buffer.from(row.public_result));}catch{fail('unauthorized',401);}if(row.session_id.startsWith('dc.')||value.purpose!==undefined)fail('unauthorized',401);}
   const body={...r};delete body.deviceProof;
   const publicKey=row?.public_key??r.devicePublicKey;
   if(!publicKey||(r.devicePublicKey!==undefined&&r.devicePublicKey!==publicKey)||sha256(publicKey)!==r.keyID||!Number.isSafeInteger(r.issuedAt)||Math.abs(config.clock.now()-r.issuedAt)>60||!signatureOK(publicKey,'football-record.device.auth-recover.v1',body,r.deviceProof))fail('unauthorized',401);
   if(!row){
     if(db.prepare("SELECT 1 FROM requests WHERE request_id=? AND operation LIKE 'deleteControl%' AND account_id=(SELECT account_id FROM devices WHERE device_id=?)").get(r.authRequestID,r.deviceID))fail('idempotencyConflict');
     const fenceID=absenceKey(r.authRequestID,r.deviceID,r.keyID),nonceHash=recoveryHash('football-record.auth-recovery-nonce.v1',[fenceID,r.nonce]);
     if(db.prepare('SELECT 1 FROM auth_recovery_nonces WHERE fence_id=? AND nonce_hash=?').get(fenceID,nonceHash))fail('unauthorized',401);
     db.prepare('INSERT INTO auth_recovery_nonces VALUES(?,?)').run(fenceID,nonceHash);
     db.prepare('INSERT OR IGNORE INTO auth_absence_fences VALUES(?)').run(fenceID);
     return {status:'knownAbandoned'};
   }
   consumeNonce(row.session_id,r.nonce);
   const s=db.prepare('SELECT * FROM sessions WHERE session_id=?').get(row.session_id);if(!s)return {status:'knownRevoked'};
   const a=db.prepare('SELECT * FROM accounts WHERE account_id=?').get(s.account_id);
   if(s.revoked||!a||a.activation_epoch!==s.activation_epoch)return {status:'knownRevoked'};
   if(s.expires_at<config.clock.now())return {status:'knownExpired'};
   return output(row.public_result,s);
 });}
 function authenticateRequest({authorization,proof,method,path,requestID,bodyBytes}){
   if(typeof authorization!=='string'||!authorization.startsWith('Bearer ')||!proof||Object.keys(proof).sort().join(',')!=='issuedAt,keyID,nonce,signature'||typeof proof.nonce!=='string'||!/^[A-Za-z0-9._:-]{1,128}$/.test(proof.nonce)||!Number.isSafeInteger(proof.issuedAt)||Math.abs(config.clock.now()-proof.issuedAt)>60)fail('unauthorized',401);
   const hash=sha256(authorization.slice(7)),s=db.prepare('SELECT * FROM sessions WHERE token_hash=?').get(hash);
   if(!s||s.revoked||s.expires_at<config.clock.now()||s.key_id!==proof.keyID)fail('unauthorized',401);
   const d=db.prepare('SELECT * FROM devices WHERE device_id=? AND account_id=?').get(s.device_id,s.account_id);
   const fields={method,path,requestID,bodySHA256:sha256(bodyBytes),sessionID:s.session_id,activationEpoch:s.activation_epoch,keyID:proof.keyID,nonce:proof.nonce,issuedAt:proof.issuedAt};
   if(!d||!signatureOK(d.public_key,'football-record.device.pop.v1',fields,proof.signature))fail('unauthorized',401);
   const ctx={accountID:s.account_id,deviceID:s.device_id,keyID:s.key_id,activationEpoch:s.activation_epoch,sessionID:s.session_id};
   return transaction(db,config,()=>{const current=db.prepare('SELECT revoked FROM sessions WHERE session_id=?').get(s.session_id);if(!current||current.revoked)fail('unauthorized',401);validate(ctx,{active:false});const operation=Object.entries(routes).find(([p])=>p===path)?.[1][0]??(method==='GET'?'requestQuery':'unknown');let payload;try{payload=method==='GET'?{requestID}:JSON.parse(bodyBytes);}catch{fail('unauthorized',401);}assertDeletionControlPurpose(state,ctx,operation,payload);consumeNonce(s.session_id,proof.nonce);return ctx;});
 }
 function watchResult(old){
   if(old.status==='knownAbandoned')return old;
   const s=db.prepare('SELECT * FROM sessions WHERE session_id=?').get(old.sessionClaims.sessionID);if(!s)fail('unauthorized',401);
   return {...old,credential:credential(s)};
 }
 function recoverWatch(ctx,r){validatePayload('recoverWatch',r);return transaction(db,config,()=>{
   assertDeletionControlPurpose(state,ctx,'registerWatch',r);const {a,d}=validate(ctx);if(d.role!=='phone'||a.active_phone_id!==ctx.deviceID)fail('activationMismatch',403);
   const old=stored(ctx,r,'registerWatch');if(old)return watchResult(old);
   checkWatchFence(ctx,r);
   const prior=db.prepare('SELECT * FROM devices WHERE device_id=?').get(r.watchID);
   if(prior&&(prior.account_id!==ctx.accountID||prior.public_key!==r.watchPublicKey||prior.role!=='watch'))fail('unauthorized',401);
   checkChallenge(r,r.watchPublicKey,r.watchID,true);
   db.prepare('INSERT INTO auth_absence_fences VALUES(?)').run(watchFenceKey(ctx,r));
   return persist(ctx,r,'registerWatch',{status:'knownAbandoned',receipt:makeReceipt(config,ctx,r,'registerWatch','knownAbandoned',{}, {registration:{watchID:r.watchID,watchPublicKey:r.watchPublicKey}})});
 });}
 function registerWatch(ctx,r){validatePayload('registerWatch',r);return transaction(db,config,()=>{
   assertDeletionControlPurpose(state,ctx,'registerWatch',r);const {a,d}=validate(ctx);if(d.role!=='phone'||a.active_phone_id!==ctx.deviceID)fail('activationMismatch',403);
   const old=stored(ctx,r,'registerWatch');if(old)return watchResult(old);
   checkWatchFence(ctx,r);
   checkChallenge(r,r.watchPublicKey,r.watchID);
   const prior=db.prepare('SELECT * FROM devices WHERE device_id=?').get(r.watchID),keyID=sha256(r.watchPublicKey);
   if(prior&&(prior.account_id!==ctx.accountID||prior.public_key!==r.watchPublicKey||prior.role!=='watch'))fail('unauthorized',401);
   if(!prior)db.prepare('INSERT INTO devices VALUES(?,?,?,?,?,?)').run(r.watchID,ctx.accountID,keyID,r.watchPublicKey,'watch',ctx.activationEpoch);
   else db.prepare("UPDATE devices SET role='watch',activation_epoch=? WHERE device_id=? AND account_id=? AND public_key=?").run(ctx.activationEpoch,r.watchID,ctx.accountID,r.watchPublicKey);
   db.prepare('UPDATE challenges SET consumed=1 WHERE challenge_id=?').run(r.challengeID);
   const s=session({...ctx,deviceID:r.watchID,keyID});const result={receipt:makeReceipt(config,ctx,r,'registerWatch','registered',{}, {registration:{watchID:r.watchID,watchPublicKey:r.watchPublicKey}}),sessionClaims:{sessionID:s.session_id,expiresAt:s.expires_at}};persist(ctx,r,'registerWatch',result);return {...result,credential:credential(s)};
 });}
 authority.registerWatch=registerWatch;authority.recoverWatch=recoverWatch;
 const control=createDeletionReauthentication(state,{appleVerifier,credential});
 return {challenge,authenticate,recover,authenticateRequest,registerWatch,recoverWatch,credential,deletionControlChallenge:control.challenge,deletionControlAuthenticate:control.authenticate,deletionControlRecover:control.recover};
}
