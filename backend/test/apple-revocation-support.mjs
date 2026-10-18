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
      reply(200,controls.exchangeRaw??((controls.exchangePrefix??'')+JSON.stringify(response)));return;
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


export async function openRevocationAuthority(options={}) {
  const {startFixtureAuthority,challengeSignature}=await import('./support.mjs');
  const {createDeviceAuth,makePoP}=await import('../src/device-auth.mjs');
  const {createHTTPServer}=await import('../src/http.mjs');
  const {createDevelopmentAppleRevoker}=await import('../src/apple-revoker.mjs');
  const {sha256}=await import('../src/receipt.mjs');
  const f=await startFixtureAuthority(),apple=await startRevocationFixture({clock:f.clock,timeoutMs:options.timeoutMs??200}),logs=[];
  let server,deviceAuth;
  async function start(){deviceAuth=createDeviceAuth({authority:f.authority,appleVerifier:apple.appleVerifier});f.config.appleRevoker=createDevelopmentAppleRevoker(apple.config);server=createHTTPServer({authority:f.authority,appleVerifier:apple.appleVerifier,deviceAuth,logger:entry=>logs.push(entry)});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));}
  await start();const raw=async(path,r,{method='POST',headers={}}={})=>{const response=await fetch(`http://127.0.0.1:${server.address().port}`+path,{method,headers:{'content-type':'application/json',...headers},body:method==='GET'?undefined:canonicalJSON(r)});const text=await response.text();return {status:response.status,data:JSON.parse(text),text};};
  function device(){const keys=generateKeyPairSync('ed25519');return {deviceID:randomUUID(),privateKey:keys.privateKey,devicePublicKey:keys.publicKey.export({type:'spki',format:'der'}).subarray(-32).toString('base64url')};}
  async function prepareLogin(d=device(),subject='account-subject-SENTINEL'){
    const challenge=(await raw('/v1/auth/challenges',{version:1,requestID:randomUUID(),deviceID:d.deviceID,devicePublicKey:d.devicePublicKey})).data;
    const claims={iss:'https://appleid.apple.com',sub:subject,aud:'test.football',nonce:sha256(challenge.challenge),iat:f.clock.now(),exp:f.clock.now()+300};
    const identityToken=apple.jwt(claims),authorizationCode='authorization-SENTINEL-'+randomUUID();apple.registerCode(authorizationCode,identityToken);
    const request={version:1,requestID:randomUUID(),challengeID:challenge.challengeID,identityToken,authorizationCode,deviceID:d.deviceID,devicePublicKey:d.devicePublicKey,cloudSpaceID:'fixture-cloud'};request.deviceProof=challengeSignature(request,challenge.challenge,d.privateKey);
    return {d,request};
  }
  async function login(d,subject){const prepared=await prepareLogin(d,subject),result=await raw('/v1/auth/apple',prepared.request);if(result.status!==200)throw Error('reference fixture auth failed');return {...prepared,result:result.data,credential:result.data.credential,context:result.data.context};
  }
  async function call(login,path,request,{method='POST'}={}){
    const bodyBytes=method==='GET'?Buffer.alloc(0):Buffer.from(canonicalJSON(request)),c=login.credential;
    const proof=makePoP(login.d.privateKey,{method,path,requestID:method==='GET'?path.split('/').at(-1):request.requestID,bodySHA256:sha256(bodyBytes),sessionID:c.sessionID,activationEpoch:c.activationEpoch,keyID:c.keyID,nonce:randomUUID(),issuedAt:f.clock.now()});
    return raw(path,request,{method,headers:{authorization:'Bearer '+c.token,'x-device-pop':Buffer.from(canonicalJSON(proof)).toString('base64url')}});
  }
  return {f,apple,logs,raw,login,prepareLogin,call,async restart(){await new Promise(resolve=>server.close(resolve));await f.restart();await start();},async close(){await new Promise(resolve=>server.close(resolve));await f.close();await apple.close();}};
}
