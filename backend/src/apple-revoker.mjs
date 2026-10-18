import {createAppleClientSecret} from './apple-client-secret.mjs';
import {isAppleVerifier,isVerifiedApple} from './apple-verifier.mjs';
import {parseStrictJSON,sha256} from './receipt.mjs';
import {fail} from './database.mjs';
const brands=new WeakMap(),MAX_RESPONSE=32768;
const allowed=['teamID','keyID','clientIDs','privateKey','appleVerifier','clock','redirectURIs'];
const id=value=>typeof value==='string'&&/^[A-Za-z0-9._:-]{1,128}$/.test(value);
const opaque=value=>typeof value==='string'&&value.length>0&&value.length<=4096&&/^[\x21-\x7e]+$/.test(value);
export function isAppleRevoker(value,environment){return brands.get(value)===environment;}
export function assertAppleRevoker(value,environment){
  if(value===undefined)return;
  if(typeof value!=='function'||(environment==='production'&&!isAppleRevoker(value,'production'))||(isAppleRevoker(value,'production')&&environment!=='production')||(isAppleRevoker(value,'development')&&environment!=='development'))throw new Error('Apple revoker environment mismatch');
}
async function boundedBody(response){
  if(!response.body)return Buffer.alloc(0);
  const reader=response.body.getReader();let size=0;const chunks=[];
  try {while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>MAX_RESPONSE){await reader.cancel();throw Error();}chunks.push(Buffer.from(value));}return Buffer.concat(chunks);}
  finally{reader.releaseLock();}
}
function checkedRedirects(value={}){
  if(!value||Object.getPrototypeOf(value)!==Object.prototype)throw Error();
  for(const [clientID,uri]of Object.entries(value)){if(!id(clientID)||typeof uri!=='string')throw Error();const u=new URL(uri);if(u.protocol!=='https:'||u.username||u.password||u.hash||u.hostname==='localhost'||/^\[|^\d+(?:\.\d+){3}$/.test(u.hostname))throw Error();}
  return Object.freeze({...value});
}
function makeRevoker(options,environment,baseURL,timeoutMs){
  let config;
  try {
    const clock=options.clock??{now:()=>Math.floor(Date.now()/1000)},redirectURIs=checkedRedirects(options.redirectURIs);
    if(!isAppleVerifier(options.appleVerifier,environment)||!Array.isArray(options.clientIDs)||!options.clientIDs.length||options.clientIDs.some(x=>!id(x))||new Set(options.clientIDs).size!==options.clientIDs.length)throw Error();
    config={...options,clock,redirectURIs,clientIDs:Object.freeze([...options.clientIDs])};
    createAppleClientSecret({...config,clientID:config.clientIDs[0]});
  }catch{throw new Error('invalid Apple revocation configuration');}
  const attempts=new Map(),codes=new Map();
  async function post(path,fields){
    return fetch(baseURL+path,{method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams(fields),redirect:'error',credentials:'omit',signal:AbortSignal.timeout(timeoutMs)});
  }
  const revoke=async input=>{
    let code,expected,refreshToken,clientSecret,exchangeBytes,responseBytes;
    try {
      if(!input||Object.keys(input).sort().join(',')!=='authorizationCode,expectedApple,reauthenticationID')throw Error();
      code=input.authorizationCode;expected=input.expectedApple;
      const now=config.clock.now();
      if(!opaque(code)||!id(input.reauthenticationID)||!isVerifiedApple(expected,environment)||expected.environment!==environment||!config.clientIDs.includes(expected.audience)||expected.issuer!=='https://appleid.apple.com'||expected.issuedAt>now+60||expected.issuedAt+300<now)throw Error();
      for(const [key,expiresAt]of attempts)if(expiresAt<now)attempts.delete(key);
      for(const [key,expiresAt]of codes)if(expiresAt<now)codes.delete(key);
      const codeHash=sha256(code);if(attempts.has(input.reauthenticationID)||codes.has(codeHash)||attempts.size>=256)throw Error();
      const originalRedirect=expected.authorizationRedirectURI;
      if(originalRedirect!==undefined&&config.redirectURIs[expected.audience]!==originalRedirect)throw Error();
      attempts.set(input.reauthenticationID,expected.issuedAt+300);codes.set(codeHash,expected.issuedAt+300);
      clientSecret=createAppleClientSecret({...config,clientID:expected.audience});
      const fields={client_id:expected.audience,client_secret:clientSecret,code,grant_type:'authorization_code'};
      if(originalRedirect!==undefined)fields.redirect_uri=originalRedirect;
      const exchange=await post('/auth/token',fields);if(exchange.status!==200)throw Error();
      if(!/^application\/json(?:\s*;.*)?$/i.test(exchange.headers.get('content-type')??''))throw Error();
      exchangeBytes=await boundedBody(exchange);
      const token=parseStrictJSON(new TextDecoder('utf-8',{fatal:true}).decode(exchangeBytes));
      const keys=['access_token','token_type','expires_in','refresh_token','id_token'];
      if(!token||Object.getPrototypeOf(token)!==Object.prototype||Object.keys(token).some(k=>!keys.includes(k))||typeof token.id_token!=='string'||token.id_token.length<1||token.id_token.length>12000||!opaque(token.refresh_token)||(token.access_token!==undefined&&!opaque(token.access_token))||token.token_type!=='Bearer'||!Number.isSafeInteger(token.expires_in)||token.expires_in<1)throw Error();
      const verified=await config.appleVerifier.verify(token.id_token,expected.nonce);
      if(!isVerifiedApple(verified,environment)||verified.issuer!==expected.issuer||verified.subject!==expected.subject||verified.audience!==expected.audience||verified.nonce!==expected.nonce||verified.environment!==expected.environment)throw Error();
      refreshToken=token.refresh_token;
      const response=await post('/auth/revoke',{client_id:expected.audience,client_secret:clientSecret,token:refreshToken,token_type_hint:'refresh_token'});
      if(response.status!==200)throw Error();responseBytes=await boundedBody(response);
      if(responseBytes.toString('utf8').trim()!=='')throw Error();return Object.freeze({revoked:true});
    }catch{fail('reauthenticationRequired',403);}
    finally {exchangeBytes?.fill(0);responseBytes?.fill(0);code=undefined;expected=undefined;refreshToken=undefined;clientSecret=undefined;}
  };
  Object.defineProperty(revoke,'environment',{value:environment,enumerable:true});brands.set(revoke,environment);return Object.freeze(revoke);
}
export function createAppleRevoker(options){
  if(!options||Object.keys(options).some(k=>!allowed.includes(k)))throw new Error('invalid Apple revocation configuration');
  return makeRevoker(options,'production','https://appleid.apple.com',5000);
}
export function createDevelopmentAppleRevoker(options){
  try{if(!options||Object.keys(options).some(k=>![...allowed,'baseURL','timeoutMs'].includes(k)))throw Error();const u=new URL(options.baseURL);if(u.protocol!=='http:'||!['127.0.0.1','[::1]'].includes(u.hostname)||u.username||u.password||u.pathname!=='/'||u.search||u.hash)throw Error();const timeout=options.timeoutMs??5000;if(!Number.isSafeInteger(timeout)||timeout<1||timeout>5000)throw Error();return makeRevoker(options,'development',u.origin,timeout);}catch{throw new Error('invalid development Apple revocation configuration');}
}
