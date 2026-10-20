import {fail} from './database.mjs';
import {canonicalJSON,sha256,decodeBase64URL} from './receipt.mjs';
import {validateMetric} from './analytics.mjs';
const definitions={
 deleteControlChallenge:'purpose deleteRequest deleteDigest accountID deviceID devicePublicKey keyID activationEpoch cloudSpaceID recoveryCapability issuedAt nonce deviceProof',deleteControlAuthentication:'purpose deleteRequest deleteDigest accountID deviceID devicePublicKey keyID activationEpoch cloudSpaceID recoveryCapability challengeID identityToken authorizationCode deviceProof',deleteControlRecover:'purpose deleteRequest deleteDigest accountID deviceID devicePublicKey keyID activationEpoch cloudSpaceID recoveryCapability authRequestID authRequestDigest issuedAt nonce deviceProof',
 challenge:'deviceID devicePublicKey',authApple:'challengeID identityToken authorizationCode deviceID devicePublicKey deviceProof cloudSpaceID',authRecover:'authRequestID deviceID keyID nonce issuedAt deviceProof',registerWatch:'watchID watchPublicKey challengeID deviceProof',recoverWatch:'watchID watchPublicKey challengeID deviceProof',
 acquire:'matchID recordingDeviceID activationEpoch',liveStatus:'acquireRequestID matchID lockID recordingDeviceID activationEpoch nonce',terminate:'matchID lockID recordingDeviceID activationEpoch mode',peerGrant:'localDeviceID remoteDeviceID activationEpoch pairingID',
 prepareMigration:'newPhoneID activationEpoch',checkpointMigration:'migrationID checkpointID contentCommitment activationEpoch',activateMigration:'migrationID checkpointID contentCommitment cloudSpaceID',requestLostMigration:'newPhoneID cloudSpaceID',lostRecovery:'migrationID reauthenticationID matchID lockID originalRecordingDeviceID originalActivationEpoch confirmedAt',terminateLost:'migrationID grantID matchID lockID originalRecordingDeviceID originalActivationEpoch',forceMigration:'migrationID reauthenticationID',deleteAccount:'reauthenticationID recoveryCapabilityDigest',deleteStatus:'deleteRequestID recoveryCapability',analytics:'metric count appVersion osFamily osMajor qualification'};
const id=value=>typeof value==='string'&&/^[A-Za-z0-9._:-]{1,128}$/.test(value);
export function validatePayload(operation,r){
 if(operation==='analytics'){validateMetric(r);return r;}
 if(!r||Object.getPrototypeOf(r)!==Object.prototype||!definitions[operation])fail('invalidPayload',422);
 let fields=['version','requestID',...definitions[operation].split(' ')];
 if(operation==='terminate'&&r.mode==='normal')fields.push('cloudConfirmationID','contentCommitment');
 if(operation==='authRecover'&&Object.hasOwn(r,'devicePublicKey'))fields.push('devicePublicKey');
 if(Object.keys(r).sort().join(',')!==fields.sort().join(',')||r.version!==1||!id(r.requestID))fail('invalidPayload',422);
 for(const field of fields){const value=r[field];if(['version','requestID'].includes(field))continue;
   if(['activationEpoch','originalActivationEpoch'].includes(field)){if(!Number.isSafeInteger(value)||value<1)fail('invalidPayload',422);}
   else if(['issuedAt','confirmedAt'].includes(field)){if(!Number.isSafeInteger(value)||value<0)fail('invalidPayload',422);}
   else if(field==='purpose'){if(value!=='deleteControl.v1')fail('invalidPayload',422);}
   else if(field==='deleteRequest'){validatePayload('deleteAccount',value);}
   else if(['contentCommitment','recoveryCapabilityDigest','deleteDigest','authRequestDigest'].includes(field)){if(typeof value!=='string'||!/^[a-f0-9]{64}$/.test(value))fail('invalidPayload',422);}
   else if(['devicePublicKey','watchPublicKey','deviceProof','recoveryCapability'].includes(field)){try{decodeBase64URL(value,field==='deviceProof'?64:32);}catch{fail('invalidPayload',422);}}
   else if(field==='identityToken'){if(typeof value!=='string'||value.length<1||value.length>12000||!/^[A-Za-z0-9._-]+$/.test(value))fail('invalidPayload',422);}
   else if(field==='authorizationCode'){if(typeof value!=='string'||value.length<1||value.length>4096||!/^[\x21-\x7e]+$/.test(value))fail('invalidPayload',422);}
   else if(field==='mode'){if(!['normal','abnormal'].includes(value))fail('invalidPayload',422);}
   else if(!id(value))fail('invalidPayload',422);
 }
 if(operation.startsWith('deleteControl')&&(sha256(canonicalJSON(r.deleteRequest))!==r.deleteDigest||r.requestID===r.deleteRequest.requestID||(operation==='deleteControlRecover'&&(r.authRequestID===r.deleteRequest.requestID||r.authRequestID===r.requestID))))fail('invalidPayload',422);
 return r;
}
export const routes={
 '/v1/accounts/delete/reauth/challenges':['deleteControlChallenge','deletionControlChallenge'],'/v1/accounts/delete/reauth/apple':['deleteControlAuthentication','deletionControlAuthenticate'],'/v1/accounts/delete/reauth/recover':['deleteControlRecover','deletionControlRecover'],
 '/v1/auth/challenges':['challenge','challenge'],'/v1/auth/apple':['authApple','authenticate'],'/v1/auth/recover':['authRecover','recover'],'/v1/devices/watches':['registerWatch','registerWatch'],'/v1/devices/watches/recover':['recoverWatch','recoverWatch'],
 '/v1/locks/acquire':['acquire','acquire'],'/v1/locks/status':['liveStatus','liveStatus'],'/v1/locks/terminate':['terminate','terminate'],'/v1/peers/grants':['peerGrant','peerGrant'],
 '/v1/migrations/prepare':['prepareMigration','prepareMigration'],'/v1/migrations/checkpoint':['checkpointMigration','checkpointMigration'],'/v1/migrations/activate':['activateMigration','activateMigration'],'/v1/migrations/lost':['requestLostMigration','requestLostMigration'],'/v1/migrations/lost-recovery':['lostRecovery','lostRecovery'],'/v1/locks/terminate-lost':['terminateLost','terminateLost'],'/v1/migrations/force':['forceMigration','forceMigration'],'/v1/accounts/delete':['deleteAccount','deleteAccount'],'/v1/accounts/delete-status':['deleteStatus','deleteStatus'],'/v1/analytics':['analytics','analytics']};
