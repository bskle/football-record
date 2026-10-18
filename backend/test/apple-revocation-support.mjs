import {createServer} from 'node:http';
import {generateKeyPairSync,randomUUID,sign,verify} from 'node:crypto';
import {createDevelopmentAppleVerifier} from '../src/apple-verifier.mjs';
import {canonicalJSON,decodeBase64URL} from '../src/receipt.mjs';
import {fixtureClock} from './support.mjs';
export async function startRevocationFixture(options={}) {
  const {createDevelopmentAppleRevoker}=await import('../src/apple-revoker.mjs');
  const clock=options.clock??fixtureClock(),rsa=generateKeyPairSync('rsa',{modulusLength:2048}),p256=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
  const jwks={keys:[{...rsa.publicKey.export({format:'jwk'}),kid:'revocation-rsa',alg:'RS256',use:'sig'}]};
  const controls={},requests=[],codes=new Map(),issued=new Map(),used=new Set(),sockets=new Set();
  const teamID='TEAM123456',keyID='KEY1234567',clientID='test.football';
  function jwt(claims,header={alg:'RS256',kid:'revocation-rsa'}) {const input=Buffer.from(JSON.stringify(header)).toString('base64url')+'.'+Buffer.from(JSON.stringify(claims)).toString('base64url');return input+'.'+sign('RSA-SHA256',Buffer.from(input),rsa.privateKey).toString('base64url');}
  function validSecret(value){try{const [h,p,s]=value.split('.'),header=JSON.parse(Buffer.from(h,'base64url')),claims=JSON.parse(Buffer.from(p,'base64url')),signature=decodeBase64URL(s,64);return Object.keys(header).sort().join(',')==='alg,kid'&&header.alg==='ES256'&&header.kid===keyID&&Object.keys(claims).sort().join(',')==='aud,exp,iat,iss,sub'&&claims.iss===teamID&&claims.sub===clientID&&claims.aud==='https://appleid.apple.com'&&claims.iat===clock.now()&&claims.exp===claims.iat+300&&verify('sha256',Buffer.from(h+'.'+p),{key:p256.publicKey,dsaEncoding:'ieee-p1363'},signature);}catch{return false;}}
  const server=createServer(async(req,res)=>{
    if(req.url==='/auth/keys'){requests.push({path:req.url});res.end(JSON.stringify(jwks));return;}
    let raw='';for await(const b of req)raw+=b;
    const form=new URLSearchParams(raw),fields=Object.fromEntries(form);requests.push({path:req.url,fields,validSecret:validSecret(fields.client_secret),contentType:req.headers['content-type']});
    const reply=(status,body)=>{res.writeHead(status,{'content-type':'application/json'});res.end(body);};
    if(req.url==='/redirect-target'){controls.redirectReached=true;reply(200,'{}');return;}
    if(!validSecret(fields.client_secret)||fields.client_id!==clientID){reply(400,'{"error":"invalid_client"}');return;}
    if(req.url==='/auth/token'){
      if(controls.exchangeEntered)controls.exchangeEntered();
      if(controls.exchangePause)await controls.exchangePause;
      if(controls.exchangeTimeout)return;
      if(controls.exchangeRedirect){res.writeHead(302,{location:baseURL+'/redirect-target'});res.end();return;}
      if(controls.exchangeStatus){reply(controls.exchangeStatus,'{"error":"'+(controls.errorSentinel??'invalid_grant')+'"}');return;}
      if(fields.grant_type!=='authorization_code'||!codes.has(fields.code)||used.has(fields.code)){reply(400,'{"error":"invalid_grant"}');return;}
      used.add(fields.code);
      if(controls.exchangeDisconnect){res.destroy();return;}
      const original=codes.get(fields.code),claims={...original,...controls.claims},header=controls.header;
      let idToken=jwt(claims,header);if(controls.badSignature)idToken=idToken.slice(0,-4)+'AAAA';
      const refresh='refresh-SENTINEL-'+randomUUID()+'+/&?';issued.set(refresh,{code:fields.code,secret:fields.client_secret});
      let response={access_token:'access-SENTINEL-'+randomUUID(),token_type:'Bearer',expires_in:3600,refresh_token:refresh,id_token:idToken,...controls.response};
      reply(200,controls.exchangeRaw??JSON.stringify(response));return;
    }
    if(req.url==='/auth/revoke'){
      if(controls.revokeEntered)controls.revokeEntered();
      if(controls.revokePause)await controls.revokePause;
      if(controls.revokeTimeout)return;
      const entry=issued.get(fields.token);
      if(!entry||entry.secret!==fields.client_secret||fields.token_type_hint!=='refresh_token'){reply(400,'{"error":"invalid_request"}');return;}
      if(controls.revokeDisconnect){res.destroy();return;}
      reply(controls.revokeStatus??200,controls.revokeBody??'');return;
    }
    reply(404,'{}');
  });
  server.on('connection',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const baseURL=`http://127.0.0.1:${server.address().port}`;
  const appleVerifier=createDevelopmentAppleVerifier({audiences:[clientID],clock,fetchJWKS:async()=>(await fetch(baseURL+'/auth/keys')).json(),redirectURIs:options.redirectURIs});
  const config={teamID,keyID,clientIDs:[clientID],privateKey:p256.privateKey,appleVerifier,clock,baseURL,timeoutMs:options.timeoutMs??500,redirectURIs:options.redirectURIs};
  const revoker=createDevelopmentAppleRevoker(config);
  async function input(overrides={}) {const claims={iss:'https://appleid.apple.com',sub:'subject-SENTINEL-'+randomUUID(),aud:clientID,nonce:'nonce-'+randomUUID(),iat:clock.now(),exp:clock.now()+300,...overrides.claims};const code='code-SENTINEL-'+randomUUID();codes.set(code,claims);const expectedApple=await appleVerifier.verify(jwt(claims),claims.nonce,overrides.flow);return {authorizationCode:code,expectedApple,reauthenticationID:randomUUID()};}
  function registerCode(code,token){const parts=token.split('.');codes.set(code,JSON.parse(Buffer.from(parts[1],'base64url')));}
  return {clock,controls,requests,codes,issued,used,config,revoker,appleVerifier,input,registerCode,jwt,validSecret,get baseURL(){return baseURL;},async close(){for(const s of sockets)s.destroy();await new Promise(resolve=>server.close(resolve));}};
}
