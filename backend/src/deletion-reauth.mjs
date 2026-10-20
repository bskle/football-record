import {createHmac,randomUUID,verify} from 'node:crypto';
import {isVerifiedApple} from './apple-verifier.mjs';
import {validatePayload} from './codec.mjs';
import {canonicalJSON,parseStrictJSON,sha256,edPublicKey,decodeBase64URL,signedBody,verifySigned,rawPublicKey} from './receipt.mjs';
import {transaction,fail} from './database.mjs';
const purpose='deleteControl.v1',domain='football-record.deletion-control.';
const bytes=x=>Buffer.from(canonicalJSON(x));
const same=(a,b)=>canonicalJSON(a)===canonicalJSON(b);
const digest=r=>sha256(canonicalJSON(r));
const context=r=>({accountID:r.accountID,deviceID:r.deviceID,devicePublicKey:r.devicePublicKey,keyID:r.keyID,activationEpoch:r.activationEpoch,cloudSpaceID:r.cloudSpaceID});
const parentFields=r=>({version:1,purpose,parentRequestID:r.deleteRequest.requestID,parentDigest:r.deleteDigest,context:context(r),deleteRequest:r.deleteRequest});
export const deletionControlID=(kind,parentID,parentDigest,childID)=>({parent:'dcp.',session:'dcs.',lock:'dck.',resolution:'dcr.'}[kind]+sha256('football-record.deletion-control-record.v1\n'+canonicalJSON([kind,parentID,parentDigest,childID])));
function signatureOK(r,suffix,extra={}){try{const b={...r,...extra};delete b.deviceProof;return verify(null,Buffer.from(domain+suffix+'.v1\n'+canonicalJSON(b)),edPublicKey(r.devicePublicKey),decodeBase64URL(r.deviceProof,64));}catch{return false;}}
const exactKeys=(v,keys)=>v&&Object.getPrototypeOf(v)===Object.prototype&&Object.keys(v).sort().join(',')===keys.split(' ').sort().join(',');
const baseKeys='version purpose parentRequestID parentDigest context deleteRequest';
function decode(row){
 try{
  const raw=Buffer.from(row.result),v=parseStrictJSON(new TextDecoder('utf-8',{fatal:true}).decode(raw));
  const suffix={deleteControlParent:'lockState lock originalAcquire',deleteControlChallenge:'challengeID',deleteControlAuthentication:'authorization originalAcquire',deleteControlSession:'sessionID authRequestID authRequestDigest',deleteControlLock:'requestID requestDigest',deleteControlResolution:'authRequestID authRequestDigest readyDigest authorization originalAcquire'};
  const kind=row.operation??(v.authorization?'deleteControlAuthentication':undefined);
  if(raw.length>32768||!raw.equals(bytes(v))||v.version!==1||v.purpose!==purpose||!suffix[kind]||!exactKeys(v,baseKeys+' '+suffix[kind])||!exactKeys(v.context,'accountID deviceID devicePublicKey keyID activationEpoch cloudSpaceID'))throw Error();
  validatePayload('deleteAccount',v.deleteRequest);
  if(v.parentRequestID!==v.deleteRequest.requestID||v.parentDigest!==digest(v.deleteRequest)||sha256(v.context.devicePublicKey)!==v.context.keyID)throw Error();
  if(kind==='deleteControlAuthentication'||kind==='deleteControlResolution'){
   const a=v.authorization?.body;
   if(!exactKeys(v.authorization,'body signature')||bytes(v.authorization).length>16384||!exactKeys(a,'version purpose environment keyID proofID requestID requestDigest parentRequestID parentDigest recoveryCapabilityDigest accountID deviceID deviceKeyID activationEpoch cloudSpaceID result stage issuedAt expiresAt sessionID reauthenticationID reauthenticationExpiresAt lockState lock')||a.version!==1||a.purpose!==purpose||a.parentRequestID!==v.parentRequestID||a.parentDigest!==v.parentDigest||!['ready','knownAbandoned','knownExpired','knownRevoked','parentUnavailable','lockMappingUnavailable'].includes(a.result)||!['unreserved','requested','lockReconciled','appleRevocation'].includes(a.stage)||!['none','pinned','unavailable'].includes(a.lockState))throw Error();
  }
  if(v.originalAcquire!==undefined&&v.originalAcquire!==null&&bytes(v.originalAcquire).length>16384)throw Error();
  const lockState=kind==='deleteControlParent'?v.lockState:v.authorization?.body?.lockState,lock=kind==='deleteControlParent'?v.lock:v.authorization?.body?.lock;
  if(lockState!==undefined){if(!['none','pinned','unavailable'].includes(lockState))throw Error();if(lockState==='pinned'){if(!exactKeys(lock,'matchID lockID recordingDeviceID activationEpoch acquireRequestID acquireRequestDigest acquireReceiptDigest')||!v.originalAcquire||sha256(bytes(v.originalAcquire))!==lock.acquireReceiptDigest)throw Error();}else if(lock!==null||v.originalAcquire!==null)throw Error();}
  return v;
 }catch{fail('unavailable',503);}
}
const rowBytes=row=>Object.values(row).reduce((n,v)=>n+(typeof v==='string'?Buffer.byteLength(v):typeof v==='number'?8:v===null?0:Buffer.from(v).length),0);
function assertPayloadBudget(state,parent,additions=[]){
 const {db,config}=state,account=parent.context.accountID;
 const added=table=>additions.filter(x=>x.table===table).map(x=>x.row);
 const all=[...db.prepare("SELECT * FROM requests WHERE account_id=? AND operation LIKE 'deleteControl%'").all(account),...added('requests')];
 const scoped=[],authIDs=new Set(),sessions=new Set(),challenges=new Set(),reauths=new Set();
 let accountAttempts=0,parentAttempts=0,total=0;
 for(const r of all){
  const v=decode(r),attempt=['deleteControlChallenge','deleteControlAuthentication'].includes(r.operation);
  if(attempt)accountAttempts++;
  if(v.parentRequestID!==parent.parentRequestID)continue;
  if(v.parentDigest!==parent.parentDigest||!same(v.context,parent.context)||!same(v.deleteRequest,parent.deleteRequest))fail('idempotencyConflict');
  scoped.push(v);total+=rowBytes(r);if(attempt)parentAttempts++;
  if(r.operation==='deleteControlAuthentication')authIDs.add(r.request_id);
  if(v.challengeID)challenges.add(v.challengeID);
  if(v.sessionID)sessions.add(v.sessionID);
  if(v.authorization?.body.sessionID)sessions.add(v.authorization.body.sessionID);
  if(v.authorization?.body.reauthenticationID)reauths.add(v.authorization.body.reauthenticationID);
 }
 // The auth_records public_result is a second durable copy, not free payload.
 const authRows=[];
 for(const r of db.prepare('SELECT * FROM auth_records WHERE account_id=?').all(account)){
  if(!r.session_id.startsWith('dc.')){let v;try{v=JSON.parse(Buffer.from(r.public_result));}catch{continue;}if(v.purpose===undefined)continue;fail('unavailable',503);}
  const v=decode({result:r.public_result});
  if(v.parentRequestID!==parent.parentRequestID)continue;
  if(v.parentDigest!==parent.parentDigest||!same(v.context,parent.context))fail('idempotencyConflict');
  authRows.push(r);authIDs.add(r.auth_request_id);sessions.add(r.session_id);
  if(v.authorization.body.reauthenticationID)reauths.add(v.authorization.body.reauthenticationID);
 }
 const include=(table,rows)=>{for(const r of [...rows,...added(table)])total+=rowBytes(r);};
 include('auth_records',authRows);
 include('sessions',[...sessions].flatMap(id=>db.prepare('SELECT * FROM sessions WHERE session_id=?').all(id)));
 include('reauthentications',[...reauths].flatMap(id=>db.prepare('SELECT * FROM reauthentications WHERE reauthentication_id=?').all(id)));
 include('challenges',[...challenges].flatMap(id=>db.prepare('SELECT * FROM challenges WHERE challenge_id=?').all(id)));
 include('challenge_requests',[...challenges].flatMap(id=>db.prepare('SELECT * FROM challenge_requests WHERE challenge_id=?').all(id)));
 include('deletions',db.prepare('SELECT * FROM deletions WHERE account_id=? AND delete_request_id=?').all(account,parent.parentRequestID));
 include('nonces',[...sessions].flatMap(id=>db.prepare('SELECT * FROM nonces WHERE session_id=?').all(id)));
 const keyed=(domain,v)=>createHmac('sha256',config.tokenDerivationKey).update(domain+'\n'+canonicalJSON(v)).digest('hex');
 const nonceScopes=['challenge','recover'].map(kind=>keyed('football-record.deletion-control.nonce.v1',[account,parent.parentRequestID,parent.parentDigest,kind]));
 include('auth_recovery_nonces',nonceScopes.flatMap(id=>db.prepare('SELECT * FROM auth_recovery_nonces WHERE fence_id=?').all(id)));
 include('auth_absence_fences',[...authIDs].flatMap(id=>db.prepare('SELECT * FROM auth_absence_fences WHERE fence_id=?').all(keyed('football-record.deletion-control.absence.v1',[parent.parentRequestID,parent.parentDigest,id,parent.context.deviceID,parent.context.keyID]))));
 if(total>4*1024*1024||parentAttempts>64||accountAttempts>256)fail('unavailable',503);
}
function put(state,r,requestID,operation,requestDigest,value){
 const {db}=state,raw=bytes(value);
 if(raw.length>32768)fail('unavailable',503);
 const prior=db.prepare('SELECT * FROM requests WHERE account_id=? AND request_id=?').get(r.accountID,requestID);
 if(prior){if(prior.operation!==operation||prior.request_digest!==requestDigest||!Buffer.from(prior.result).equals(raw))fail('idempotencyConflict');return decode(prior);}
 const item={account_id:r.accountID,request_id:requestID,operation,request_digest:requestDigest,result:raw};
 assertPayloadBudget(state,value,[{table:'requests',row:item}]);
 db.prepare('INSERT INTO requests VALUES(?,?,?,?,?)').run(r.accountID,requestID,operation,requestDigest,raw);return value;
}
function row(db,accountID,id,operation){const raw=db.prepare('SELECT * FROM requests WHERE account_id=? AND request_id=?').get(accountID,id);if(raw&&raw.operation!==operation)fail('idempotencyConflict');return raw?{raw,value:decode(raw)}:undefined;}
function matchParent(v,r){if(!same(parentFields(r),{version:v.version,purpose:v.purpose,parentRequestID:v.parentRequestID,parentDigest:v.parentDigest,context:v.context,deleteRequest:v.deleteRequest}))fail('idempotencyConflict');}
export function createDeletionReauthentication(state,{appleVerifier,credential}){
 const {db,config,validate}=state;
 const keyed=(d,v)=>createHmac('sha256',config.tokenDerivationKey).update(d+'\n'+canonicalJSON(v)).digest('hex');
 const fence=r=>keyed('football-record.deletion-control.absence.v1',[r.deleteRequest.requestID,r.deleteDigest,r.authRequestID??r.requestID,r.deviceID,r.keyID]);
 function exact(r){if(sha256(r.devicePublicKey)!==r.keyID||sha256(r.recoveryCapability)!==r.deleteRequest.recoveryCapabilityDigest)fail('unauthorized',401);const {a,d}=validate(r);if(d.role!=='phone'||a.active_phone_id!==r.deviceID||d.public_key!==r.devicePublicKey||a.cloud_space_id!==r.cloudSpaceID)fail('unauthorized',401);if(a.migration_id)fail('migrationBlocked');const pending=db.prepare('SELECT * FROM deletions WHERE account_id=?').get(r.accountID);if(pending&&(pending.device_id!==r.deviceID||pending.delete_request_id!==r.deleteRequest.requestID||pending.request_digest!==r.deleteDigest||pending.recovery_hash!==r.deleteRequest.recoveryCapabilityDigest))fail('idempotencyConflict');return pending;}
 function ended(r){if(db.prepare('SELECT 1 FROM accounts WHERE account_id=?').get(r.accountID))return;const rec=db.prepare('SELECT result FROM deletion_receipts WHERE delete_request_id=? AND recovery_hash=? AND expires_at>=?').get(r.deleteRequest.requestID,sha256(r.recoveryCapability),config.clock.now());return rec?{status:'backendDeleted',receipt:parseStrictJSON(Buffer.from(rec.result).toString('utf8'))}:{status:'receiptExpired'};}
 function checkOrdinaryAbsence(r,id){if(db.prepare('SELECT 1 FROM auth_absence_fences WHERE fence_id=?').get(keyed('football-record.auth-absence.v1',[id,r.deviceID,r.keyID])))fail('idempotencyConflict');}
 function freshness(r,suffix){if(Math.abs(config.clock.now()-r.issuedAt)>60||!signatureOK(r,suffix))fail('unauthorized',401);}
 function consume(r,scope){const id=keyed('football-record.deletion-control.nonce.v1',[r.accountID,r.deleteRequest.requestID,r.deleteDigest,scope]),nonce=keyed('football-record.deletion-control.nonce-hash.v1',[id,r.nonce]);if(db.prepare('SELECT 1 FROM auth_recovery_nonces WHERE fence_id=? AND nonce_hash=?').get(id,nonce))fail('unauthorized',401);assertPayloadBudget(state,parentFields(r),[{table:'auth_recovery_nonces',row:{fence_id:id,nonce_hash:nonce}}]);db.prepare('INSERT INTO auth_recovery_nonces VALUES(?,?)').run(id,nonce);}
 function challenge(r){validatePayload('deleteControlChallenge',r);freshness(r,'challenge');return transaction(db,config,()=>{const done=ended(r);if(done)return done;exact(r);checkOrdinaryAbsence(r,r.requestID);const prior=row(db,r.accountID,r.requestID,'deleteControlChallenge');let c;if(prior){if(prior.raw.request_digest!==digest(r))fail('idempotencyConflict');matchParent(prior.value,r);c=db.prepare('SELECT * FROM challenges WHERE challenge_id=?').get(prior.value.challengeID);if(!c)fail('unavailable',503);}else{if(db.prepare('SELECT 1 FROM challenge_requests WHERE request_id=?').get(r.requestID))fail('idempotencyConflict');consume(r,'challenge');c={challenge_id:randomUUID(),device_id:r.deviceID,key_fingerprint:r.keyID,expires_at:config.clock.now()+300,consumed:0};const claims={...parentFields(r),challengeID:c.challenge_id,expiresAt:c.expires_at};const secret=keyed(domain+'challenge-secret.v1',claims);db.prepare('INSERT INTO challenges VALUES(?,?,?,?,?,0)').run(c.challenge_id,sha256(secret),r.deviceID,r.keyID,c.expires_at);db.prepare('INSERT INTO challenge_requests VALUES(?,?,?)').run(r.requestID,digest(r),c.challenge_id);put(state,r,r.requestID,'deleteControlChallenge',digest(r),{...parentFields(r),challengeID:c.challenge_id});}
 const claims={...parentFields(r),challengeID:c.challenge_id,expiresAt:c.expires_at},response={version:1,purpose,requestID:r.requestID,challengeID:c.challenge_id,expiresAt:c.expires_at};return c.consumed?{...response,status:'consumed'}:c.expires_at<config.clock.now()?{...response,status:'expired'}:{...response,challenge:keyed(domain+'challenge-secret.v1',claims)};});}
 function checkChallenge(r){const c=db.prepare('SELECT * FROM challenges WHERE challenge_id=?').get(r.challengeID),cr=db.prepare('SELECT * FROM challenge_requests WHERE challenge_id=?').get(r.challengeID);if(!c||!cr||c.consumed||c.expires_at<config.clock.now()||c.device_id!==r.deviceID||c.key_fingerprint!==r.keyID)fail('unauthorized',401);const saved=row(db,r.accountID,cr.request_id,'deleteControlChallenge');if(!saved)fail('unauthorized',401);matchParent(saved.value,r);if(!signatureOK(r,'authenticate',{challengeSHA256:c.challenge_hash}))fail('unauthorized',401);return c;}
 function proof(r,{result='ready',stage='unreserved',sessionID=null,reauthenticationID=null,reauthenticationExpiresAt=null,expiresAt=config.clock.now(),pin={lockState:'none',lock:null}}={}){return signedBody(config.receiptPrivateKey,{version:1,purpose,environment:config.environment,keyID:config.receiptKeyID,proofID:randomUUID(),requestID:r.authRequestID??r.requestID,requestDigest:r.authRequestDigest??digest(r),parentRequestID:r.deleteRequest.requestID,parentDigest:r.deleteDigest,recoveryCapabilityDigest:r.deleteRequest.recoveryCapabilityDigest,accountID:r.accountID,deviceID:r.deviceID,deviceKeyID:r.keyID,activationEpoch:r.activationEpoch,cloudSpaceID:r.cloudSpaceID,result,stage,issuedAt:config.clock.now(),expiresAt,sessionID,reauthenticationID,reauthenticationExpiresAt,lockState:pin.lockState,lock:pin.lock},'football-record.deletion-control-auth.v1');}
 function parent(r){return row(db,r.accountID,deletionControlID('parent',r.deleteRequest.requestID,r.deleteDigest,''),'deleteControlParent');}
 function pin(r,pending){const old=parent(r);if(old){matchParent(old.value,r);return old.value;}const lock=db.prepare('SELECT * FROM active_locks WHERE account_id=?').get(r.accountID);let lockState='none',value=null,originalAcquire=null;
 if(lock){const candidates=db.prepare("SELECT * FROM requests WHERE account_id=? AND operation='acquire'").all(r.accountID).filter(x=>{try{const raw=Buffer.from(x.result),a=parseStrictJSON(raw.toString('utf8')),b=a.body;return raw.length<=16384&&raw.equals(bytes(a))&&verifySigned(rawPublicKey(config.receiptPrivateKey),a)&&b.version===1&&b.environment===config.environment&&b.keyID===config.receiptKeyID&&b.requestID===x.request_id&&b.requestDigest===x.request_digest&&b.operation==='acquire'&&b.result==='held'&&b.accountID===r.accountID&&b.activationEpoch===lock.activation_epoch&&b.matchID===lock.match_id&&b.lockID===lock.lock_id&&b.recordingDeviceID===lock.recorder_id&&b.issuedAt<=pending.requested_at;}catch{return false;}});if(candidates.length===1){const a=candidates[0];originalAcquire=parseStrictJSON(Buffer.from(a.result).toString('utf8'));value={matchID:lock.match_id,lockID:lock.lock_id,recordingDeviceID:lock.recorder_id,activationEpoch:lock.activation_epoch,acquireRequestID:a.request_id,acquireRequestDigest:a.request_digest,acquireReceiptDigest:sha256(Buffer.from(a.result))};lockState='pinned';}else lockState='unavailable';}
 const v={...parentFields(r),lockState,lock:value,originalAcquire};put(state,r,deletionControlID('parent',r.deleteRequest.requestID,r.deleteDigest,''),'deleteControlParent',r.deleteDigest,v);return v;}
 function output(v,s){validatedControlChain(state,{accountID:s.account_id,deviceID:s.device_id,keyID:s.key_id,activationEpoch:s.activation_epoch,sessionID:s.session_id});const a=v.authorization?.body;if(!a||!verifySigned(rawPublicKey(config.receiptPrivateKey),v.authorization,'football-record.deletion-control-auth.v1')||a.sessionID!==s.session_id||a.accountID!==s.account_id||a.deviceID!==s.device_id||a.deviceKeyID!==s.key_id||a.activationEpoch!==s.activation_epoch)fail('unavailable',503);return {authorization:v.authorization,originalAcquire:v.originalAcquire,credential:credential(s)};}
 async function authenticate(r){validatePayload('deleteControlAuthentication',r);const done=ended(r);if(done)return done;exact(r);const c=checkChallenge(r),verified=await appleVerifier.verify(r.identityToken,c.challenge_hash);if(!isVerifiedApple(verified,config.environment)||createHmac('sha256',config.accountHMACKey).update(verified.issuer+'\n'+verified.subject).digest('hex')!==r.accountID||Math.abs(config.clock.now()-verified.issuedAt)>300)fail('unauthorized',401);state.pruneReauthMaterial();let reauthID;
 try{return transaction(db,config,()=>{const completed=ended(r);if(completed)return completed;let pending=exact(r);checkChallenge(r);checkOrdinaryAbsence(r,r.requestID);if(db.prepare('SELECT 1 FROM challenge_requests WHERE request_id=?').get(r.requestID))fail('idempotencyConflict');if(db.prepare('SELECT 1 FROM auth_absence_fences WHERE fence_id=?').get(fence(r)))fail('unauthorized',401);if(db.prepare('SELECT 1 FROM auth_records WHERE auth_request_id=? AND device_id=?').get(r.requestID,r.deviceID)||db.prepare('SELECT 1 FROM requests WHERE account_id=? AND request_id=?').get(r.accountID,r.requestID))fail('idempotencyConflict');
 if(!pending){if(db.prepare('SELECT 1 FROM requests WHERE account_id=? AND request_id=?').get(r.accountID,r.deleteRequest.requestID))fail('idempotencyConflict');db.prepare('INSERT INTO deletions VALUES(?,?,?,?,?,?,?,?)').run(r.accountID,r.deviceID,r.deleteRequest.requestID,r.deleteDigest,r.deleteRequest.recoveryCapabilityDigest,'requested',r.deleteRequest.reauthenticationID,config.clock.now());pending=exact(r);}const p=pin(r,pending),ctx={accountID:r.accountID,deviceID:r.deviceID,keyID:r.keyID,activationEpoch:r.activationEpoch};
 if(['requested','lockReconciled'].includes(pending.state)){reauthID=randomUUID();db.prepare('INSERT INTO reauthentications VALUES(?,?,?,?,?,?,0)').run(reauthID,r.accountID,r.deviceID,r.keyID,verified.issuedAt,verified.issuedAt+300);state.storeReauthMaterial(reauthID,{authorizationCode:r.authorizationCode,expectedApple:verified,binding:Object.freeze({...ctx,reauthenticationID:reauthID}),expiresAt:verified.issuedAt+300});db.prepare('UPDATE deletions SET reauthentication_id=? WHERE account_id=? AND delete_request_id=? AND request_digest=?').run(reauthID,r.accountID,r.deleteRequest.requestID,r.deleteDigest);}else if(pending.state!=='appleRevocation')fail('unavailable',503);
 const s={session_id:'dc.'+randomUUID(),account_id:r.accountID,device_id:r.deviceID,key_id:r.keyID,activation_epoch:r.activationEpoch,expires_at:config.clock.now()+300},cred=credential(s);db.prepare('INSERT INTO sessions VALUES(?,?,?,?,?,?,?,0)').run(s.session_id,s.account_id,s.device_id,s.key_id,s.activation_epoch,s.expires_at,sha256(cred.token));
 const authorization=proof(r,{stage:pending.state,sessionID:s.session_id,reauthenticationID:reauthID??null,reauthenticationExpiresAt:reauthID?verified.issuedAt+300:null,expiresAt:s.expires_at,pin:p});const v={...parentFields(r),authorization,originalAcquire:p.originalAcquire};put(state,r,r.requestID,'deleteControlAuthentication',digest(r),v);assertPayloadBudget(state,parentFields(r),[{table:'auth_records',row:{auth_request_id:r.requestID,device_id:r.deviceID,account_id:r.accountID,request_digest:digest(r),public_key:r.devicePublicKey,session_id:s.session_id,public_result:bytes(v)}}]);db.prepare('INSERT INTO auth_records VALUES(?,?,?,?,?,?,?)').run(r.requestID,r.deviceID,r.accountID,digest(r),r.devicePublicKey,s.session_id,bytes(v));put(state,r,deletionControlID('session',r.deleteRequest.requestID,r.deleteDigest,s.session_id),'deleteControlSession',digest(r),{...parentFields(r),sessionID:s.session_id,authRequestID:r.requestID,authRequestDigest:digest(r)});db.prepare('UPDATE challenges SET consumed=1 WHERE challenge_id=?').run(r.challengeID);return output(v,s);});}catch(e){if(reauthID&&!db.prepare('SELECT 1 FROM reauthentications WHERE reauthentication_id=?').get(reauthID))state.dropReauthMaterial(reauthID);throw e;}}
 function recover(r){
  validatePayload('deleteControlRecover',r);freshness(r,'recover');
  return transaction(db,config,()=>{
   const done=ended(r);if(done)return done;
   const pending=exact(r);checkOrdinaryAbsence(r,r.authRequestID);consume(r,'recover');
   if(db.prepare('SELECT 1 FROM challenge_requests WHERE request_id=?').get(r.authRequestID))fail('idempotencyConflict');
   const saved=row(db,r.accountID,r.authRequestID,'deleteControlAuthentication');
   if(!saved){
    if(db.prepare('SELECT 1 FROM auth_records WHERE auth_request_id=? AND device_id=?').get(r.authRequestID,r.deviceID))fail('idempotencyConflict');
    assertPayloadBudget(state,parentFields(r),[{table:'auth_absence_fences',row:{fence_id:fence(r)}}]);db.prepare('INSERT OR IGNORE INTO auth_absence_fences VALUES(?)').run(fence(r));
    const v={...parentFields(r),authorization:proof(r,{result:'knownAbandoned',stage:pending?.state??'unreserved'}),originalAcquire:null};
    put(state,r,r.authRequestID,'deleteControlAuthentication',r.authRequestDigest,v);
    return {authorization:v.authorization,originalAcquire:null,credential:null};
   }
   matchParent(saved.value,r);
   if(saved.raw.request_digest!==r.authRequestDigest)fail('idempotencyConflict');
   const a=saved.value.authorization.body;
   if(a.result!=='ready'){
    validateClosedProof(saved.value.authorization,r,config,['knownAbandoned']);
    return {authorization:saved.value.authorization,originalAcquire:null,credential:null};
   }
   // Expiry and revocation are facts only after the complete historical chain is
   // verified. They must never turn missing or damaged metadata into a signed close.
   const chain=validatedControlChain(state,{accountID:r.accountID,deviceID:r.deviceID,keyID:r.keyID,activationEpoch:r.activationEpoch,sessionID:a.sessionID},{historical:true});
   const s=chain.session,id=deletionControlID('resolution',r.deleteRequest.requestID,r.deleteDigest,r.authRequestID);
   const prior=row(db,r.accountID,id,'deleteControlResolution');
   if(prior){validateResolution(prior,r,saved.value,config);return {authorization:prior.value.authorization,originalAcquire:null,credential:null};}
   if(s.revoked||s.expires_at<config.clock.now()){
    const v={...parentFields(r),authRequestID:r.authRequestID,authRequestDigest:r.authRequestDigest,readyDigest:sha256(bytes(saved.value.authorization)),authorization:proof(r,{result:s.revoked?'knownRevoked':'knownExpired',stage:pending.state}),originalAcquire:null};
    put(state,r,id,'deleteControlResolution',r.authRequestDigest,v);
    return {authorization:v.authorization,originalAcquire:null,credential:null};
   }
   return output(saved.value,s);
  });
 }
 return {challenge,authenticate,recover};
}

// Historical validation is distinct from current credential admission. It allows
// original expiry/revocation facts, while requiring all original signed and SQL
// evidence. Neither path authorizes by the dc marker alone.
function validatedControlChain(state,ctx,{historical=false}={}){
 const {db,config}=state;
 if(typeof ctx.sessionID!=='string')fail('unauthorized',401);
 const records=db.prepare('SELECT * FROM auth_records WHERE session_id=?').all(ctx.sessionID);
 if(!ctx.sessionID.startsWith('dc.')||records.length!==1)fail('unauthorized',401);
 const record=records[0],value=decode({result:record.public_result}),a=value.authorization.body,c=value.context;
 const session=db.prepare('SELECT * FROM sessions WHERE session_id=?').get(ctx.sessionID);
 if(!session||![0,1].includes(session.revoked)||(!historical&&(session.revoked||session.expires_at<config.clock.now())))fail('unauthorized',401);
 const claims={sessionID:session.session_id,accountID:session.account_id,deviceID:session.device_id,keyID:session.key_id,activationEpoch:session.activation_epoch,expiresAt:session.expires_at};
 const expectedToken=createHmac('sha256',config.tokenDerivationKey).update('football-record.session.v1\n'+canonicalJSON(claims)).digest('base64url');
 if(session.token_hash!==sha256(expectedToken)||session.account_id!==ctx.accountID||session.device_id!==ctx.deviceID||session.key_id!==ctx.keyID||session.activation_epoch!==ctx.activationEpoch||record.account_id!==ctx.accountID||record.device_id!==ctx.deviceID||record.public_key!==c.devicePublicKey||a.version!==1||a.purpose!==purpose||a.environment!==config.environment||a.keyID!==config.receiptKeyID||a.result!=='ready'||!verifySigned(rawPublicKey(config.receiptPrivateKey),value.authorization,'football-record.deletion-control-auth.v1'))fail('unauthorized',401);
 if(a.sessionID!==session.session_id||a.expiresAt!==session.expires_at||!Number.isSafeInteger(a.issuedAt)||a.issuedAt<0||!Number.isSafeInteger(a.expiresAt)||a.expiresAt-a.issuedAt!==300||a.accountID!==ctx.accountID||a.deviceID!==ctx.deviceID||a.deviceKeyID!==ctx.keyID||a.activationEpoch!==ctx.activationEpoch||a.cloudSpaceID!==c.cloudSpaceID||a.requestID!==record.auth_request_id||a.requestDigest!==record.request_digest||a.parentRequestID!==value.parentRequestID||a.parentDigest!==value.parentDigest||a.recoveryCapabilityDigest!==value.deleteRequest.recoveryCapabilityDigest||c.accountID!==ctx.accountID||c.deviceID!==ctx.deviceID||c.keyID!==ctx.keyID||c.activationEpoch!==ctx.activationEpoch)fail('unauthorized',401);
 const account=db.prepare('SELECT * FROM accounts WHERE account_id=?').get(ctx.accountID),device=db.prepare('SELECT * FROM devices WHERE account_id=? AND device_id=?').get(ctx.accountID,ctx.deviceID),pending=db.prepare('SELECT * FROM deletions WHERE account_id=?').get(ctx.accountID);
 if(!account||!device||account.cloud_space_id!==c.cloudSpaceID||account.active_phone_id!==ctx.deviceID||account.activation_epoch!==ctx.activationEpoch||device.public_key!==c.devicePublicKey||device.key_id!==ctx.keyID||device.role!=='phone'||device.activation_epoch!==ctx.activationEpoch||!pending||pending.device_id!==ctx.deviceID||pending.delete_request_id!==value.parentRequestID||pending.request_digest!==value.parentDigest||pending.recovery_hash!==value.deleteRequest.recoveryCapabilityDigest||!['requested','lockReconciled','appleRevocation'].includes(pending.state))fail('unauthorized',401);
 if(a.reauthenticationID!==null){
  const reauth=db.prepare('SELECT * FROM reauthentications WHERE reauthentication_id=?').get(a.reauthenticationID);
  if(!reauth||reauth.account_id!==ctx.accountID||reauth.device_id!==ctx.deviceID||reauth.key_id!==ctx.keyID||reauth.expires_at!==a.reauthenticationExpiresAt||reauth.issued_at> a.issuedAt+60||reauth.expires_at-reauth.issued_at!==300||!['requested','lockReconciled'].includes(a.stage))fail('unauthorized',401);
 }else if(a.reauthenticationExpiresAt!==null||a.stage!=='appleRevocation')fail('unauthorized',401);
 const p=row(db,ctx.accountID,deletionControlID('parent',value.parentRequestID,value.parentDigest,''),'deleteControlParent'),m=row(db,ctx.accountID,deletionControlID('session',value.parentRequestID,value.parentDigest,ctx.sessionID),'deleteControlSession'),original=row(db,ctx.accountID,a.requestID,'deleteControlAuthentication');
 if(!p||!m||!original||p.raw.request_digest!==value.parentDigest||m.raw.request_digest!==a.requestDigest||original.raw.request_digest!==a.requestDigest||!Buffer.from(original.raw.result).equals(Buffer.from(record.public_result))||m.value.sessionID!==ctx.sessionID||m.value.authRequestID!==a.requestID||m.value.authRequestDigest!==a.requestDigest||!same(m.value.context,c)||!same(p.value.context,c)||m.value.parentDigest!==value.parentDigest||p.value.parentDigest!==value.parentDigest||m.value.parentRequestID!==value.parentRequestID||p.value.parentRequestID!==value.parentRequestID||!same(p.value.deleteRequest,value.deleteRequest)||!same(m.value.deleteRequest,value.deleteRequest)||!same(p.value.lock,a.lock)||p.value.lockState!==a.lockState||!same(p.value.originalAcquire,value.originalAcquire))fail('unauthorized',401);
 if(p.value.lockState==='pinned'&&!verifySigned(rawPublicKey(config.receiptPrivateKey),p.value.originalAcquire))fail('unauthorized',401);
 const resolution=row(db,ctx.accountID,deletionControlID('resolution',value.parentRequestID,value.parentDigest,a.requestID),'deleteControlResolution');
 if(resolution){const r={...c,deleteRequest:value.deleteRequest,deleteDigest:value.parentDigest,authRequestID:a.requestID,authRequestDigest:a.requestDigest};validateResolution(resolution,r,value,config);if(!historical)fail('unauthorized',401);}
 return {value,parent:p,session};
}
function validateClosedProof(authorization,r,config,results){
 const b=authorization.body;
 if(b.version!==1||b.purpose!==purpose||b.environment!==config.environment||b.keyID!==config.receiptKeyID||!results.includes(b.result)||b.requestID!==r.authRequestID||b.requestDigest!==r.authRequestDigest||b.parentRequestID!==r.deleteRequest.requestID||b.parentDigest!==r.deleteDigest||b.recoveryCapabilityDigest!==r.deleteRequest.recoveryCapabilityDigest||b.accountID!==r.accountID||b.deviceID!==r.deviceID||b.deviceKeyID!==r.keyID||b.activationEpoch!==r.activationEpoch||b.cloudSpaceID!==r.cloudSpaceID||b.sessionID!==null||b.reauthenticationID!==null||b.reauthenticationExpiresAt!==null||b.lockState!=='none'||b.lock!==null||b.expiresAt!==b.issuedAt||!Number.isSafeInteger(b.issuedAt)||b.issuedAt<0||b.issuedAt>9007199254740991||typeof b.proofID!=='string'||!/^[A-Za-z0-9._:-]{1,128}$/.test(b.proofID)||!['unreserved','requested','lockReconciled','appleRevocation'].includes(b.stage)||!verifySigned(rawPublicKey(config.receiptPrivateKey),authorization,'football-record.deletion-control-auth.v1'))fail('unavailable',503);
}
function validateResolution(saved,r,ready,config){
 const v=saved.value,b=v.authorization.body;
 matchParent(v,r);validateClosedProof(v.authorization,r,config,['knownExpired','knownRevoked']);
 if(saved.raw.request_digest!==r.authRequestDigest||v.authRequestID!==r.authRequestID||v.authRequestDigest!==r.authRequestDigest||v.readyDigest!==sha256(bytes(ready.authorization))||b.requestID!==r.authRequestID||b.requestDigest!==r.authRequestDigest||b.parentRequestID!==r.deleteRequest.requestID||b.parentDigest!==r.deleteDigest||b.recoveryCapabilityDigest!==r.deleteRequest.recoveryCapabilityDigest||b.accountID!==r.accountID||b.deviceID!==r.deviceID||b.deviceKeyID!==r.keyID||b.activationEpoch!==r.activationEpoch||b.cloudSpaceID!==r.cloudSpaceID||b.environment!==config.environment||b.keyID!==config.receiptKeyID||!['knownExpired','knownRevoked'].includes(b.result)||b.sessionID!==null||b.reauthenticationID!==null||b.reauthenticationExpiresAt!==null||b.expiresAt!==b.issuedAt||!Number.isSafeInteger(b.issuedAt)||b.issuedAt<0||!verifySigned(rawPublicKey(config.receiptPrivateKey),v.authorization,'football-record.deletion-control-auth.v1'))fail('unavailable',503);
}
export function assertDeletionControlPurpose(state,ctx,operation,r){
 const {db}=state;if(!ctx.sessionID)return;
 const records=db.prepare('SELECT public_result FROM auth_records WHERE session_id=?').all(ctx.sessionID);
 const looksControl=ctx.sessionID.startsWith('dc.')||records.some(x=>{try{return JSON.parse(Buffer.from(x.public_result)).purpose!==undefined;}catch{return true;}});
 if(!looksControl)return;
 const chain=validatedControlChain(state,ctx),value=chain.value,p=chain.parent,c=value.context;
 if(operation==='deleteAccount'){if(!same(r,value.deleteRequest))fail('unauthorized',401);return;}
 const pin=p.value.lock;
 if(operation==='requestQuery'){
  if(r.requestID===value.parentRequestID)return;
  if(p.value.lockState==='pinned'&&r.requestID===pin.acquireRequestID)return;
  const l=row(db,ctx.accountID,deletionControlID('lock',value.parentRequestID,value.parentDigest,''),'deleteControlLock');if(l&&l.value.requestID===r.requestID&&l.value.parentDigest===value.parentDigest&&l.value.parentRequestID===value.parentRequestID&&same(l.value.context,c))return;
  fail('unauthorized',401);
 }
 if(!['liveStatus','terminate'].includes(operation)||p.value.lockState!=='pinned'||!pin||r.matchID!==pin.matchID||r.lockID!==pin.lockID||r.recordingDeviceID!==pin.recordingDeviceID||r.activationEpoch!==pin.activationEpoch)fail('unauthorized',401);
 if(operation==='liveStatus'){if(r.acquireRequestID!==pin.acquireRequestID)fail('unauthorized',401);return;}
 if(r.mode!=='abnormal')fail('unauthorized',401);
 const id=deletionControlID('lock',value.parentRequestID,value.parentDigest,''),old=row(db,ctx.accountID,id,'deleteControlLock');
 if(old){if(old.value.requestID!==r.requestID||old.value.requestDigest!==digest(r)||!same(old.value.context,c)||old.value.parentDigest!==value.parentDigest||old.value.parentRequestID!==value.parentRequestID)fail('unauthorized',401);}
 else{const current=db.prepare('SELECT * FROM active_locks WHERE account_id=?').get(ctx.accountID);if(!current||current.lock_id!==pin.lockID||current.match_id!==pin.matchID||current.recorder_id!==pin.recordingDeviceID||current.activation_epoch!==pin.activationEpoch)fail('unauthorized',401);put(state,{accountID:ctx.accountID,deleteRequest:value.deleteRequest},id,'deleteControlLock',digest(r),{version:1,purpose,parentRequestID:value.parentRequestID,parentDigest:value.parentDigest,context:c,deleteRequest:value.deleteRequest,requestID:r.requestID,requestDigest:digest(r)});}
}

// Ordinary PoP nonce storage is unchanged; only this dedicated session's parent
// is charged before inserting another nonce into the shared original table.
export function assertDeletionControlNonceBudget(state,sessionID,nonce){
 if(!sessionID.startsWith('dc.'))return;
 const record=state.db.prepare('SELECT public_result FROM auth_records WHERE session_id=?').all(sessionID);
 if(record.length!==1)fail('unauthorized',401);
 const parent=decode({result:record[0].public_result});
 assertPayloadBudget(state,parent,[{table:'nonces',row:{session_id:sessionID,nonce}}]);
}
