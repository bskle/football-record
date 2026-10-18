import {createPublicKey,verify} from 'node:crypto';
import {decodeBase64URL,parseStrictJSON} from './receipt.mjs';
import {fail} from './database.mjs';
const verifierBrands=new WeakMap(),identityBrands=new WeakMap();
export const isAppleVerifier=(value,environment)=>verifierBrands.get(value)===environment;
export const isVerifiedApple=(value,environment)=>identityBrands.get(value)===environment;
const TRUSTED_JWKS='https://appleid.apple.com/auth/keys';
function verifier({audiences,clock,fetchJWKS,environment,redirectURIs={}}){
  if(!Array.isArray(audiences)||!audiences.length)throw Error('explicit Apple audience allowlist required');
  let cache,validUntil=0,inflight;
  async function refresh(){if(!inflight)inflight=(async()=>{try{const result=await fetchJWKS();if(!result||!Array.isArray(result.keys)||result.keys.length>32)fail('unavailable',503,true);cache=result;validUntil=clock.now()+3600;return cache;}catch{fail('unavailable',503,true);}finally{inflight=undefined;}})();return inflight;}
  async function check(token,nonce,flow={}){
    let header,claims,signature,parts;
    try{if(typeof token!=='string'||token.length>12000)throw Error();parts=token.split('.');if(parts.length!==3)throw Error();header=parseStrictJSON(decodeBase64URL(parts[0]).toString('utf8'));claims=parseStrictJSON(decodeBase64URL(parts[1]).toString('utf8'));signature=decodeBase64URL(parts[2]);}catch{fail('unauthorized',401);}
    if(header.alg!=='RS256'||typeof header.kid!=='string'||Object.keys(header).some(k=>!['alg','kid','typ'].includes(k)))fail('unauthorized',401);
    let fresh=false;if(!cache||clock.now()>=validUntil){await refresh();fresh=true;}
    let key=cache.keys.find(k=>k.kid===header.kid);
    if(!key&&!fresh){await refresh();key=cache.keys.find(k=>k.kid===header.kid);}
    if(!key||key.kty!=='RSA'||key.alg!=='RS256'||key.use!=='sig')fail('unauthorized',401);
    try{if(!verify('RSA-SHA256',Buffer.from(parts[0]+'.'+parts[1]),createPublicKey({key,format:'jwk'}),signature))fail('unauthorized',401);}catch{fail('unauthorized',401);}
    const now=clock.now();
    if(claims.iss!=='https://appleid.apple.com'||!audiences.includes(claims.aud)||claims.nonce!==nonce||typeof claims.sub!=='string'||!claims.sub.length||claims.sub.length>256||!Number.isSafeInteger(claims.exp)||!Number.isSafeInteger(claims.iat)||claims.exp<now-60||claims.iat>now+60||claims.iat>claims.exp)fail('unauthorized',401);
    const identity={issuer:claims.iss,subject:claims.sub,audience:claims.aud,nonce:claims.nonce,issuedAt:claims.iat,environment};
    if(!flow||Object.keys(flow).some(k=>k!=='authorizationRedirectURI'))fail('unauthorized',401);
    if(flow.authorizationRedirectURI!==undefined){if(typeof flow.authorizationRedirectURI!=='string'||redirectURIs[claims.aud]!==flow.authorizationRedirectURI)fail('unauthorized',401);identity.authorizationRedirectURI=flow.authorizationRedirectURI;}
    identityBrands.set(identity,environment);return Object.freeze(identity);
  }
  const api={verify:check,environment};verifierBrands.set(api,environment);return Object.freeze(api);
}
export function createAppleVerifier({audiences,clock={now:()=>Math.floor(Date.now()/1000)},environment='production',redirectURIs={}}){
  if(!['development','production'].includes(environment))throw Error('invalid verifier environment');
  return verifier({audiences,clock,environment,redirectURIs,fetchJWKS:async()=>{const response=await fetch(TRUSTED_JWKS,{redirect:'error',signal:AbortSignal.timeout(5000)});if(!response.ok)throw Error();const bytes=Buffer.from(await response.arrayBuffer());if(bytes.length>65536)throw Error();return parseStrictJSON(bytes.toString('utf8'));}});
}
export function createDevelopmentAppleVerifier({audiences,clock,fetchJWKS,redirectURIs={}}){return verifier({audiences,clock,fetchJWKS,redirectURIs,environment:'development'});}
