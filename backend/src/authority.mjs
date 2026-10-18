import {isVerifiedApple} from './apple-verifier.mjs';
import {validatePayload} from './codec.mjs';
import {installLifecycle} from './lifecycle.mjs';
import {randomUUID,createHmac} from 'node:crypto';
import {authorityConfig} from './config.mjs';
import {openDatabase,transaction,fail} from './database.mjs';
import {canonicalJSON,makeReceipt,sha256,signedBody} from './receipt.mjs';
const states=new WeakMap();
export const authorityState=authority=>states.get(authority);
export function createAuthority(options) {
  const config=authorityConfig(options),db=openDatabase(config);
  function validate(ctx,{active=true}={}){
    const a=db.prepare('SELECT * FROM accounts WHERE account_id=?').get(ctx.accountID);
    const d=db.prepare('SELECT * FROM devices WHERE device_id=? AND account_id=?').get(ctx.deviceID,ctx.accountID);
    if(!a||!d||d.key_id!==ctx.keyID)fail('unauthorized',401);
    if(ctx.activationEpoch!==a.activation_epoch||d.activation_epoch!==ctx.activationEpoch)fail('activationMismatch',403);
    if(active && (d.role==='waiting'||(d.role==='phone'&&a.active_phone_id!==d.device_id)))fail('activationMismatch',403);
    return {a,d};
  }
  function stored(ctx,r,operation){
    const reservation=db.prepare('SELECT request_digest FROM deletions WHERE account_id=? AND delete_request_id=?').get(ctx.accountID,r.requestID);
    if(reservation&&(operation!=='deleteAccount'||reservation.request_digest!==sha256(canonicalJSON(r))))fail('idempotencyConflict');
    const prior=db.prepare('SELECT * FROM requests WHERE account_id=? AND request_id=?').get(ctx.accountID,r.requestID);
    if(prior){if(prior.operation!==operation||prior.request_digest!==sha256(canonicalJSON(r)))fail('idempotencyConflict');return JSON.parse(Buffer.from(prior.result));}
  }
  function persist(ctx,r,op,result){const bytes=Buffer.from(canonicalJSON(result));db.prepare('INSERT INTO requests VALUES(?,?,?,?,?)').run(ctx.accountID,r.requestID,op,sha256(canonicalJSON(r)),bytes);return JSON.parse(bytes);}
  function write(ctx,r,op,body,{active=true}={}){validatePayload(op,r);return transaction(db,config,()=>{const auth=validate(ctx,{active}); const old=stored(ctx,r,op);if(old)return old;return persist(ctx,r,op,body(auth));});}
  function acquire(ctx,r){return write(ctx,r,'acquire',({a})=>{
    if(a.migration_id||db.prepare('SELECT 1 FROM deletions WHERE account_id=?').get(ctx.accountID))fail('migrationBlocked');
    if(r.activationEpoch!==ctx.activationEpoch)fail('activationMismatch',403);
    const recorder=db.prepare('SELECT * FROM devices WHERE account_id=? AND device_id=? AND activation_epoch=?').get(ctx.accountID,r.recordingDeviceID,ctx.activationEpoch);
    if(!recorder||recorder.role==='waiting'||(ctx.deviceID!==r.recordingDeviceID&&ctx.deviceID!==a.active_phone_id))fail('activationMismatch',403);
    let lock=db.prepare('SELECT * FROM active_locks WHERE account_id=?').get(ctx.accountID);
    if(lock)return makeReceipt(config,ctx,r,'acquire','originalMatch',lock);
    lock={lock_id:randomUUID(),match_id:r.matchID,recorder_id:r.recordingDeviceID,activation_epoch:r.activationEpoch};
    db.prepare('INSERT INTO active_locks VALUES(?,?,?,?,?)').run(ctx.accountID,lock.lock_id,lock.match_id,lock.recorder_id,lock.activation_epoch);
    return makeReceipt(config,ctx,r,'acquire','held',lock);
  });}
  function terminate(ctx,r){return write(ctx,r,'terminate',({a,d})=>{
    if(r.activationEpoch!==ctx.activationEpoch)fail('activationMismatch',403);
    const lock=db.prepare('SELECT * FROM active_locks WHERE account_id=?').get(ctx.accountID);
    if(!lock||lock.lock_id!==r.lockID||lock.match_id!==r.matchID||lock.recorder_id!==r.recordingDeviceID||lock.activation_epoch!==r.activationEpoch)fail('lockMismatch');
    if(r.mode==='abnormal'){if(d.role!=='phone'||ctx.deviceID!==a.active_phone_id)fail('activationMismatch',403);}
    else if(r.mode==='normal'){if(ctx.deviceID!==lock.recorder_id)fail('activationMismatch',403);if(!r.cloudConfirmationID||!/^[a-f0-9]{64}$/.test(r.contentCommitment??''))fail('invalidPayload',422);}
    else fail('invalidPayload',422);
    const result=r.mode==='normal'?'releasedNormal':'releasedAbnormal';
    db.prepare('DELETE FROM active_locks WHERE account_id=? AND lock_id=? AND match_id=? AND recorder_id=? AND activation_epoch=?').run(ctx.accountID,r.lockID,r.matchID,r.recordingDeviceID,r.activationEpoch);
    db.prepare('INSERT INTO terminal_locks VALUES(?,?,?,?,?,?)').run(ctx.accountID,lock.lock_id,lock.match_id,lock.recorder_id,lock.activation_epoch,result);
    return makeReceipt(config,ctx,r,'terminate',result,lock);
  });}
  function liveStatus(ctx,r){validatePayload('liveStatus',r);return transaction(db,config,()=>{
    const {a}=validate(ctx);if(ctx.deviceID!==r.recordingDeviceID&&ctx.deviceID!==a.active_phone_id)fail('activationMismatch',403);
    const raw=db.prepare('SELECT result,operation FROM requests WHERE account_id=? AND request_id=?').get(ctx.accountID,r.acquireRequestID);
    if(!raw||raw.operation!=='acquire')fail('lockMismatch');
    const receipt=JSON.parse(Buffer.from(raw.result)).body;
    const lock=db.prepare('SELECT * FROM active_locks WHERE account_id=?').get(ctx.accountID);
    const terminal=db.prepare('SELECT * FROM terminal_locks WHERE account_id=? AND lock_id=?').get(ctx.accountID,r.lockID);
    const matches=receipt.matchID===r.matchID&&receipt.lockID===r.lockID&&receipt.recordingDeviceID===r.recordingDeviceID&&receipt.activationEpoch===r.activationEpoch;
    const held=matches&&lock?.lock_id===r.lockID&&lock.match_id===r.matchID&&lock.recorder_id===r.recordingDeviceID&&lock.activation_epoch===r.activationEpoch;
    return signedBody(config.receiptPrivateKey,{...r,accountID:ctx.accountID,receiptID:receipt.receiptID,environment:config.environment,keyID:config.receiptKeyID,requestDigest:sha256(canonicalJSON(r)),status:held?'held':matches&&terminal?'terminal':'mismatch',observedAt:config.clock.now(),expiresAt:config.clock.now()+60},'football-record.authority.live-lock.v1');
  });}
  function requestBytes(ctx,id){return transaction(db,config,()=>{validate(ctx,{active:false});const row=db.prepare('SELECT result FROM requests WHERE account_id=? AND request_id=?').get(ctx.accountID,id);if(!row){if(db.prepare('SELECT 1 FROM deletions WHERE account_id=? AND delete_request_id=?').get(ctx.accountID,id))fail('unavailable',503,true);fail('notFound',404);}return Buffer.from(row.result);});}
  const transientReauthCodes=new Map();
  const disposeReauthMaterial=material=>{
    if(material&&typeof material==='object'){material.authorizationCode='';material.expectedApple=undefined;material.binding=undefined;material.expiresAt=0;}
  };
  function dropReauthMaterial(id){const material=transientReauthCodes.get(id);transientReauthCodes.delete(id);disposeReauthMaterial(material);}
  function pruneReauthMaterial(){
    for(const [id,material]of transientReauthCodes){
      if(!material||typeof material!=='object'||material.expiresAt<config.clock.now()||!db.prepare('SELECT 1 FROM reauthentications WHERE reauthentication_id=?').get(id))dropReauthMaterial(id);
    }
  }
  function storeReauthMaterial(id,material){
    pruneReauthMaterial();dropReauthMaterial(id);
    if(transientReauthCodes.size>=256)dropReauthMaterial(transientReauthCodes.keys().next().value);
    transientReauthCodes.set(id,material);
  }
  function takeReauthMaterial(id,ctx){
    pruneReauthMaterial();const material=transientReauthCodes.get(id);transientReauthCodes.delete(id);
    const binding=material?.binding;
    if(!material||!binding||binding.reauthenticationID!==id||binding.accountID!==ctx.accountID||binding.deviceID!==ctx.deviceID||binding.keyID!==ctx.keyID||binding.activationEpoch!==ctx.activationEpoch||!isVerifiedApple(material.expectedApple,config.environment)||createHmac('sha256',config.accountHMACKey).update(material.expectedApple.issuer+'\n'+material.expectedApple.subject).digest('hex')!==ctx.accountID){
      disposeReauthMaterial(material);fail('reauthenticationRequired',403);
    }
    return material;
  }
  function clearReauthMaterial(){for(const id of transientReauthCodes.keys())dropReauthMaterial(id);}
  const api={acquire,terminate,liveStatus,requestBytes,close:()=>{clearReauthMaterial();db.close();}};
  const state={db,config,validate,stored,persist,write,transientReauthCodes,storeReauthMaterial,takeReauthMaterial,dropReauthMaterial,pruneReauthMaterial,disposeReauthMaterial};
  states.set(api,state);installLifecycle(api,state);return api;
}
