import {assertAppleRevoker} from './apple-revoker.mjs';
import {createPrivateKey,createPublicKey} from 'node:crypto';
import {isAbsolute} from 'node:path';
import {sha256} from './receipt.mjs';
export function authorityConfig(options) {
  const {databasePath,accountHMACKey,tokenDerivationKey,receiptPrivateKey}=options;
  if(typeof databasePath!=='string'||!isAbsolute(databasePath)||!Buffer.isBuffer(accountHMACKey)||accountHMACKey.length<32||!Buffer.isBuffer(tokenDerivationKey)||tokenDerivationKey.length<32||!receiptPrivateKey) throw new Error('explicit persistent database and keys required');
  const key=typeof receiptPrivateKey==='string'?createPrivateKey(receiptPrivateKey):receiptPrivateKey;
  if(key.asymmetricKeyType!=='ed25519') throw new Error('Ed25519 receipt key required');
  const environment=options.environment??'development';
  if(!['development','production'].includes(environment)) throw new Error('invalid environment');
  assertAppleRevoker(options.appleRevoker,environment);
  return {...options,receiptPrivateKey:key,environment,receiptKeyID:options.receiptKeyID??'authority-v1',clock:options.clock??{now:()=>Math.floor(Date.now()/1000)},fingerprint:sha256(Buffer.concat([accountHMACKey,tokenDerivationKey,createPublicKey(key).export({type:'spki',format:'der'}),Buffer.from(environment)]))};
}
