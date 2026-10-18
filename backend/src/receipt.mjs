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

// Parse before normal JSON decoding so duplicate keys cannot disappear in JSON.parse.
export function parseStrictJSON(source){
  let i=0;const ws=()=>{while(/[ \t\r\n]/.test(source[i]??'')&&i<source.length)i++;};
  function string(){const start=i++;for(;i<source.length;i++){if(source[i]==='\\'){i++;continue;}if(source[i]==='"'){i++;return JSON.parse(source.slice(start,i));}}throw Error('invalid JSON');}
  function value(){ws();const c=source[i];if(c==='"')return string();if(c==='{'){i++;ws();const o=Object.create(null),keys=new Set();if(source[i]==='}'){i++;return {};}while(true){ws();if(source[i]!=='"')throw Error('invalid JSON');const key=string();if(keys.has(key))throw Error('duplicate key');keys.add(key);ws();if(source[i++]!==':')throw Error('invalid JSON');o[key]=value();ws();const end=source[i++];if(end==='}')return Object.fromEntries(Object.entries(o));if(end!==',')throw Error('invalid JSON');}}
    if(c==='['){i++;const a=[];ws();if(source[i]===']'){i++;return a;}while(true){a.push(value());ws();const e=source[i++];if(e===']')return a;if(e!==',')throw Error('invalid JSON');}}
    const m=source.slice(i).match(/^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/);if(!m)throw Error('invalid JSON');i+=m[0].length;return JSON.parse(m[0]);}
  const result=value();ws();if(i!==source.length)throw Error('invalid JSON');return result;
}
