import {assertAppleRevoker} from './apple-revoker.mjs';
import {validatePayload} from './codec.mjs';
import {randomUUID,timingSafeEqual} from 'node:crypto';
import {transaction,fail,nextEpoch} from './database.mjs';
import {canonicalJSON,sha256,makeReceipt,decodeBase64URL} from './receipt.mjs';
import {validateMetric} from './analytics.mjs';
export function installLifecycle(api,state){
 const {db,config,validate,stored,persist,write}=state;
 const migrationDTO=m=>({migrationID:m.migration_id,kind:m.kind,state:m.state,oldPhoneID:m.old_phone_id,newPhoneID:m.new_phone_id,oldActivationEpoch:m.old_epoch,cloudSpaceID:m.cloud_space_id,requestedAt:m.requested_at,eligibleAt:m.eligible_at,checkpointID:m.checkpoint_id,contentCommitment:m.content_commitment});
 const noDeletion=ctx=>{if(db.prepare('SELECT 1 FROM deletions WHERE account_id=?').get(ctx.accountID))fail('migrationBlocked');};
 const activeLock=account=>db.prepare('SELECT * FROM active_locks WHERE account_id=?').get(account);
 function migration(ctx,id){noDeletion(ctx);const m=db.prepare('SELECT * FROM migrations WHERE migration_id=? AND account_id=?').get(id,ctx.accountID);if(!m)fail('migrationBlocked');return m;}
 function reauth(ctx,id,min=0){const r=db.prepare('SELECT * FROM reauthentications WHERE reauthentication_id=?').get(id);if(!r||r.account_id!==ctx.accountID||r.device_id!==ctx.deviceID||r.key_id!==ctx.keyID||r.consumed||r.issued_at<min||r.issued_at>config.clock.now()+60||r.expires_at<config.clock.now())fail('reauthenticationRequired',403);return r;}
 const consume=id=>db.prepare('UPDATE reauthentications SET consumed=1 WHERE reauthentication_id=?').run(id);
 function prepareMigration(ctx,r){return write(ctx,r,'prepareMigration',({a,d})=>{
   if(d.role!=='phone'||a.active_phone_id!==ctx.deviceID||r.activationEpoch!==ctx.activationEpoch)fail('activationMismatch',403);
   noDeletion(ctx);if(activeLock(ctx.accountID)||a.migration_id)fail('migrationBlocked');
   const target=db.prepare("SELECT * FROM devices WHERE device_id=? AND account_id=? AND role='waiting' AND activation_epoch=?").get(r.newPhoneID,ctx.accountID,ctx.activationEpoch);if(!target)fail('migrationBlocked');
   const id=randomUUID(),now=config.clock.now();db.prepare('INSERT INTO migrations VALUES(?,?,?,?,?,?,?,?,?,?,?,?)').run(id,ctx.accountID,'normal','oldPhonePrepared',ctx.deviceID,r.newPhoneID,ctx.activationEpoch,a.cloud_space_id,now,now,'','');
   db.prepare('UPDATE accounts SET migration_id=? WHERE account_id=?').run(id,ctx.accountID);
   return makeReceipt(config,ctx,r,'prepareMigration','waitingMigration',{}, {migration:migrationDTO(migration(ctx,id))});
 });}
 function checkpointMigration(ctx,r){return write(ctx,r,'checkpointMigration',({a})=>{
   const m=migration(ctx,r.migrationID);if(m.kind!=='normal'||m.state!=='oldPhonePrepared'||m.old_phone_id!==ctx.deviceID||a.active_phone_id!==ctx.deviceID||r.activationEpoch!==m.old_epoch||activeLock(ctx.accountID))fail('migrationBlocked');
   db.prepare("UPDATE migrations SET state='oldPhoneDeactivated',checkpoint_id=?,content_commitment=? WHERE migration_id=?").run(r.checkpointID,r.contentCommitment,r.migrationID);
   db.prepare("UPDATE accounts SET active_phone_id='' WHERE account_id=?").run(ctx.accountID);
   return makeReceipt(config,ctx,r,'checkpointMigration','checkpointAccepted',{}, {migration:migrationDTO(migration(ctx,m.migration_id))});
 },{active:false});}
 function activate(ctx,r,m){
   const epoch=nextEpoch(db),newctx={...ctx,activationEpoch:epoch};
   db.prepare("UPDATE accounts SET active_phone_id=?,activation_epoch=?,migration_id='' WHERE account_id=? AND activation_epoch=? AND migration_id=?").run(ctx.deviceID,epoch,ctx.accountID,m.old_epoch,m.migration_id);
   db.prepare("UPDATE devices SET role='phone',activation_epoch=? WHERE account_id=? AND device_id=?").run(epoch,ctx.accountID,ctx.deviceID);
   db.prepare('UPDATE sessions SET revoked=1 WHERE account_id=?').run(ctx.accountID);
   db.prepare("UPDATE migrations SET state='activated' WHERE migration_id=?").run(m.migration_id);
   return makeReceipt(config,newctx,r,m.kind==='normal'?'activateMigration':'forceMigration','activated',{}, {migration:migrationDTO(migration(newctx,m.migration_id))});
 }
 function activateMigration(ctx,r){return write(ctx,r,'activateMigration',({a,d})=>{
   const m=migration(ctx,r.migrationID);if(r.cloudSpaceID!==a.cloud_space_id||r.cloudSpaceID!==m.cloud_space_id)fail('cloudIdentityMismatch',403);
   if(d.role!=='waiting'||m.kind!=='normal'||m.state!=='oldPhoneDeactivated'||m.new_phone_id!==ctx.deviceID||m.old_epoch!==ctx.activationEpoch||m.checkpoint_id!==r.checkpointID||m.content_commitment!==r.contentCommitment||a.active_phone_id||activeLock(ctx.accountID))fail('migrationBlocked');
   return activate(ctx,r,m);
 },{active:false});}
 function requestLostMigration(ctx,r){return write(ctx,r,'requestLostMigration',({a,d})=>{
   noDeletion(ctx);if(d.role!=='waiting'||r.newPhoneID!==ctx.deviceID)fail('activationMismatch',403);if(r.cloudSpaceID!==a.cloud_space_id)fail('cloudIdentityMismatch',403);
   let m=a.migration_id?migration(ctx,a.migration_id):undefined;
   if(m&&(m.kind!=='lost'||m.new_phone_id!==ctx.deviceID||m.state==='activated'))fail('migrationBlocked');
   if(!m){const id=randomUUID(),now=config.clock.now();db.prepare('INSERT INTO migrations VALUES(?,?,?,?,?,?,?,?,?,?,?,?)').run(id,ctx.accountID,'lost','waitingPeriod',a.active_phone_id,ctx.deviceID,ctx.activationEpoch,a.cloud_space_id,now,now+604800,'','');db.prepare('UPDATE accounts SET migration_id=? WHERE account_id=?').run(id,ctx.accountID);m=migration(ctx,id);}
   return makeReceipt(config,ctx,r,'requestLostMigration','waitingPeriod',{}, {migration:migrationDTO(m)});
 },{active:false});}
 function lostReady(ctx,r){const m=migration(ctx,r.migrationID);if(m.kind!=='lost'||m.state==='activated'||m.new_phone_id!==ctx.deviceID||m.old_epoch!==ctx.activationEpoch)fail('migrationBlocked');if(config.clock.now()<m.eligible_at)fail('waitingPeriod');return m;}
 function lostRecovery(ctx,r){return write(ctx,r,'lostRecovery',()=>{
   const m=lostReady(ctx,r);reauth(ctx,r.reauthenticationID,m.eligible_at);const lock=activeLock(ctx.accountID);
   if(!lock||lock.lock_id!==r.lockID||lock.match_id!==r.matchID||lock.recorder_id!==r.originalRecordingDeviceID||lock.activation_epoch!==r.originalActivationEpoch)fail('lockMismatch');
   if(r.confirmedAt>config.clock.now()+60)fail('invalidPayload',422);
   const grantID=randomUUID(),expiresAt=config.clock.now()+300;
   db.prepare('INSERT INTO lost_grants VALUES(?,?,?,?,?,?,?,?,?,?,0)').run(grantID,ctx.accountID,m.migration_id,ctx.deviceID,ctx.keyID,lock.match_id,lock.lock_id,lock.recorder_id,lock.activation_epoch,expiresAt);consume(r.reauthenticationID);
   return makeReceipt(config,ctx,r,'lostRecovery','grantIssued',lock,{lostRecovery:{grantID,migrationID:m.migration_id,newPhoneID:ctx.deviceID,expiresAt}});
 },{active:false});}
 function terminateLost(ctx,r){return write(ctx,r,'terminateLost',()=>{
   lostReady(ctx,r);const g=db.prepare('SELECT * FROM lost_grants WHERE grant_id=? AND account_id=?').get(r.grantID,ctx.accountID),lock=activeLock(ctx.accountID);
   if(!g||g.consumed||g.expires_at<config.clock.now()||g.new_phone_id!==ctx.deviceID||g.key_id!==ctx.keyID||g.migration_id!==r.migrationID||g.lock_id!==r.lockID||g.match_id!==r.matchID||g.recorder_id!==r.originalRecordingDeviceID||g.old_epoch!==r.originalActivationEpoch||!lock||lock.lock_id!==g.lock_id||lock.match_id!==g.match_id||lock.recorder_id!==g.recorder_id||lock.activation_epoch!==g.old_epoch)fail('lockMismatch');
   db.prepare('DELETE FROM active_locks WHERE account_id=? AND lock_id=?').run(ctx.accountID,g.lock_id);
   db.prepare('INSERT INTO terminal_locks VALUES(?,?,?,?,?,?)').run(ctx.accountID,g.lock_id,g.match_id,g.recorder_id,g.old_epoch,'releasedAbnormal');
   db.prepare('UPDATE lost_grants SET consumed=1 WHERE grant_id=?').run(g.grant_id);
   return makeReceipt(config,ctx,r,'terminateLost','releasedAbnormal',lock);
 },{active:false});}
 function forceMigration(ctx,r){return write(ctx,r,'forceMigration',()=>{
   const m=lostReady(ctx,r);reauth(ctx,r.reauthenticationID,m.eligible_at);if(activeLock(ctx.accountID))fail('migrationBlocked');consume(r.reauthenticationID);return activate(ctx,r,m);
 },{active:false});}
 function peerGrant(ctx,r){return write(ctx,r,'peerGrant',({a})=>{
   if(ctx.deviceID!==a.active_phone_id||r.activationEpoch!==ctx.activationEpoch)fail('activationMismatch',403);
   const local=db.prepare('SELECT * FROM devices WHERE device_id=? AND account_id=? AND activation_epoch=?').get(r.localDeviceID,ctx.accountID,ctx.activationEpoch),remote=db.prepare('SELECT * FROM devices WHERE device_id=? AND account_id=? AND activation_epoch=?').get(r.remoteDeviceID,ctx.accountID,ctx.activationEpoch);
   if(!local||!remote||local.role==='waiting'||remote.role==='waiting'||local.device_id===remote.device_id)fail('activationMismatch',403);
   const prior=db.prepare('SELECT * FROM peer_grants WHERE account_id=? AND activation_epoch=? AND pairing_id=?').get(ctx.accountID,ctx.activationEpoch,r.pairingID);if(prior&&(prior.local_device_id!==r.localDeviceID||prior.remote_device_id!==r.remoteDeviceID))fail('idempotencyConflict');
   const grantID=prior?.grant_id??randomUUID(),grant={grantID,pairingID:r.pairingID,localDeviceID:local.device_id,remoteDeviceID:remote.device_id,localPublicKey:local.public_key,remotePublicKey:remote.public_key,expiresAt:config.clock.now()+3600};
   const result=makeReceipt(config,ctx,r,'peerGrant','grantIssued',{}, {peerGrant:grant});db.prepare('INSERT INTO peer_grants VALUES(?,?,?,?,?,?,?) ON CONFLICT(grant_id) DO UPDATE SET result=excluded.result').run(grantID,ctx.accountID,ctx.activationEpoch,r.pairingID,local.device_id,remote.device_id,Buffer.from(canonicalJSON(result)));return result;
 });}
 function deleteStatus(r){
   validatePayload('deleteStatus',r);
   let cap;try{cap=decodeBase64URL(r.recoveryCapability,32);}catch{fail('unauthorized',401);}
   return transaction(db,config,()=>{
    db.prepare('DELETE FROM deletion_receipts WHERE expires_at<?').run(config.clock.now());
    const rows=db.prepare('SELECT * FROM deletion_receipts WHERE delete_request_id=?').all(r.deleteRequestID);
    if(!rows.length)return {status:'receiptExpired'};
    const hash=sha256(r.recoveryCapability),row=rows.find(x=>timingSafeEqual(Buffer.from(x.recovery_hash,'hex'),Buffer.from(hash,'hex')));
    if(!row)fail('unauthorized',401);return {status:'backendDeleted',receipt:JSON.parse(Buffer.from(row.result))};
   });
 }
 async function deleteAccount(ctx,r){
   validatePayload('deleteAccount',r);state.pruneReauthMaterial();
   const saga=transaction(db,config,()=>{
     const {a,d}=validate(ctx);if(d.role!=='phone'||a.active_phone_id!==ctx.deviceID)fail('activationMismatch',403);
     stored(ctx,r,'deleteAccount');if(a.migration_id)fail('migrationBlocked');
     let s=db.prepare('SELECT * FROM deletions WHERE account_id=?').get(ctx.accountID),digest=sha256(canonicalJSON(r));
     if(s&&(s.delete_request_id!==r.requestID||s.request_digest!==digest))fail('idempotencyConflict');
     if(!s){reauth(ctx,r.reauthenticationID);db.prepare('INSERT INTO deletions VALUES(?,?,?,?,?,?,?,?)').run(ctx.accountID,ctx.deviceID,r.requestID,digest,r.recoveryCapabilityDigest,'requested',r.reauthenticationID,config.clock.now());s=db.prepare('SELECT * FROM deletions WHERE account_id=?').get(ctx.accountID);}
     return s;
   });
   if(saga.state==='requested')transaction(db,config,()=>{validate(ctx);if(activeLock(ctx.accountID))fail('activeMatchExists');if(config.faults?.lifecycleStep==='lockReconciled')fail('unavailable',503,true);db.prepare("UPDATE deletions SET state='lockReconciled' WHERE account_id=?").run(ctx.accountID);});
   let stage=db.prepare('SELECT * FROM deletions WHERE account_id=?').get(ctx.accountID);
   if(stage.state==='lockReconciled'){
     const id=stage.reauthentication_id;
     if(typeof config.appleRevoker!=='function')fail('unavailable',503,true);
     try{assertAppleRevoker(config.appleRevoker,config.environment);}catch{fail('unavailable',503,true);}
     let material;
     try {
       transaction(db,config,()=>{validate(ctx);reauth(ctx,id);material=state.takeReauthMaterial(id,ctx);consume(id);});
       try {
         const answer=await config.appleRevoker({authorizationCode:material.authorizationCode,expectedApple:material.expectedApple,reauthenticationID:id});
         if(answer?.revoked!==true)throw Error();
       }catch{fail('reauthenticationRequired',403);}
       transaction(db,config,()=>{validate(ctx);const pending=db.prepare('SELECT * FROM deletions WHERE account_id=?').get(ctx.accountID);if(!pending||pending.delete_request_id!==r.requestID||pending.request_digest!==sha256(canonicalJSON(r))||pending.state!=='lockReconciled'||pending.reauthentication_id!==id)fail('reauthenticationRequired',403);if(config.faults?.lifecycleStep==='appleRevocation')fail('unavailable',503,true);db.prepare("UPDATE deletions SET state='appleRevocation' WHERE account_id=?").run(ctx.accountID);});
     } finally {state.disposeReauthMaterial(material);}
   }
   return transaction(db,config,()=>{
     validate(ctx);if(activeLock(ctx.accountID))fail('activeMatchExists');const s=db.prepare('SELECT * FROM deletions WHERE account_id=?').get(ctx.accountID);if(s.state!=='appleRevocation')fail('reauthenticationRequired',403);
     if(config.faults?.lifecycleStep==='backendDeleted')fail('unavailable',503,true);
     const result=makeReceipt(config,ctx,r,'deleteAccount','deleted',{}, {deletion:{backend:'backendDeleted',apple:'revoked',cloud:'clientManaged',local:'clientManaged',health:'separateConfirmation'}});
     db.prepare('INSERT INTO deletion_receipts VALUES(?,?,?,?)').run(r.requestID,s.recovery_hash,Buffer.from(canonicalJSON(result)),config.clock.now()+2592000);
     db.prepare('DELETE FROM challenge_requests WHERE challenge_id IN (SELECT challenge_id FROM challenges WHERE device_id IN (SELECT device_id FROM devices WHERE account_id=?))').run(ctx.accountID);
     db.prepare('DELETE FROM challenges WHERE device_id IN (SELECT device_id FROM devices WHERE account_id=?)').run(ctx.accountID);
     db.prepare('DELETE FROM nonces WHERE session_id IN (SELECT session_id FROM sessions WHERE account_id=?)').run(ctx.accountID);
     for(const table of ['accounts','devices','active_locks','terminal_locks','requests','auth_records','sessions','reauthentications','migrations','lost_grants','peer_grants','deletions','qualifications','restrictions','analytics_events'])db.prepare('DELETE FROM '+table+' WHERE account_id=?').run(ctx.accountID);
     state.pruneReauthMaterial();
     if(config.faults?.afterDeleteCommitResponseLost){db.exec('COMMIT');fail('responseLost',503,true);}
     return result;
   });
 }
 function analytics(ctx,r){validateMetric(r);return write(ctx,r,'analytics',()=>{
   const accepted=config.analyticsEnabled===true;
   if(accepted){const day=Math.floor(config.clock.now()/86400);db.prepare('INSERT INTO analytics_events VALUES(?,?,?,?,?,?,?,?,?)').run(ctx.accountID,r.requestID,day,r.metric,r.count,r.appVersion,r.osFamily,r.osMajor,r.qualification);db.prepare('INSERT INTO analytics_aggregate VALUES(?,?,?) ON CONFLICT(day,metric) DO UPDATE SET count=count+excluded.count').run(day,r.metric,r.count);}
   return {version:1,requestID:r.requestID,accepted};
 });}
 function analyticsSummary(){
   const day=Math.floor(config.clock.now()/86400),active=days=>db.prepare('SELECT count(DISTINCT account_id) AS n FROM analytics_events WHERE day>=?').get(day-days+1).n;
   const metrics=db.prepare('SELECT day,metric,sum(count) AS count FROM analytics_aggregate GROUP BY day,metric').all();
   const total=metric=>metrics.filter(x=>x.metric===metric).reduce((sum,x)=>sum+x.count,0),ratio=(success,failure)=>({succeeded:total(success),total:total(success)+total(failure)});
   return {dau:active(1),wau:active(7),mau:active(30),matchCount:total('matchCompleted')+total('matchIncomplete'),rates:{sync:ratio('syncSucceeded','syncFailed'),recovery:ratio('recoverySucceeded','recoveryFailed')},metrics,
    devices:db.prepare('SELECT role,count(*) AS count FROM devices GROUP BY role').all(),qualifications:db.prepare("SELECT coalesce(q.qualification,'free') AS qualification,count(*) AS count FROM accounts a LEFT JOIN qualifications q ON q.account_id=a.account_id GROUP BY coalesce(q.qualification,'free')").all(),
    versions:db.prepare('SELECT app_version AS appVersion,count(DISTINCT account_id) AS accounts FROM analytics_events GROUP BY app_version').all(),lastActive:db.prepare('SELECT account_id AS accountID,max(day) AS lastActiveDay FROM analytics_events GROUP BY account_id').all()};
 }

 Object.assign(api,{prepareMigration,checkpointMigration,activateMigration,requestLostMigration,lostRecovery,terminateLost,forceMigration,peerGrant,deleteAccount,deleteStatus,analytics,analyticsSummary});
}
