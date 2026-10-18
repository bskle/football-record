import {createHash,createPublicKey,sign,verify,randomUUID} from 'node:crypto';
export const sha256 = value => createHash('sha256').update(value).digest('hex');
export function canonicalJSON(value) {
  if (value===null || typeof value==='boolean' || typeof value==='string') return JSON.stringify(value);
  if (typeof value==='number' && Number.isSafeInteger(value)) return String(value);
  if (Array.isArray(value)) return '['+value.map(canonicalJSON).join(',')+']';
  if (value && Object.getPrototypeOf(value)===Object.prototype) return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonicalJSON(value[k])).join(',')+'}';
  throw new TypeError('noncanonical value');
}
export function decodeBase64URL(value,size) {
  if(typeof value!=='string'|| !/^[A-Za-z0-9_-]+$/.test(value)) throw new Error('invalid base64url');
  const bytes=Buffer.from(value,'base64url');
  if(bytes.toString('base64url')!==value || (size!==undefined&&bytes.length!==size)) throw new Error('invalid base64url');
  return bytes;
}
export function rawPublicKey(key) {return createPublicKey(key).export({format:'der',type:'spki'}).subarray(-32).toString('base64url');}
export function edPublicKey(raw) {
  const bytes=decodeBase64URL(raw,32);
  return createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),bytes]),format:'der',type:'spki'});
}
export function signedBody(privateKey,body,domain='football-record.authority.receipt.v1') {
  return JSON.parse(canonicalJSON({body,signature:sign(null,Buffer.from(domain+'\n'+canonicalJSON(body)),privateKey).toString('base64url')}));
}
export function verifySigned(publicKey,envelope,domain='football-record.authority.receipt.v1') {
  try {return verify(null,Buffer.from(domain+'\n'+canonicalJSON(envelope.body)),edPublicKey(publicKey),decodeBase64URL(envelope.signature,64));} catch {return false;}
}
export function makeReceipt(config,ctx,request,operation,result,lock={},extra={}) {
  return signedBody(config.receiptPrivateKey,{version:1,environment:config.environment,keyID:config.receiptKeyID,receiptID:randomUUID(),requestID:request.requestID,requestDigest:sha256(canonicalJSON(request)),operation,accountID:ctx.accountID,activationEpoch:ctx.activationEpoch,matchID:lock.match_id??'',lockID:lock.lock_id??'',recordingDeviceID:lock.recorder_id??'',result,issuedAt:config.clock.now(),...extra});
}
