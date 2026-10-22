import {mkdtempSync,existsSync,openSync,closeSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,isAbsolute} from 'node:path';
import {generateKeyPairSync,randomBytes,randomUUID} from 'node:crypto';
import {createAuthority,authorityState} from '../../backend/src/authority.mjs';
import {createHTTPServer} from '../../backend/src/http.mjs';
import {authSetup,appleJWT} from '../../backend/test/support.mjs';
import {rawPublicKey,sha256} from '../../backend/src/receipt.mjs';
import {accountIDForAppleIdentity} from '../../backend/src/device-auth.mjs';
import {isAppleVerifier,isVerifiedApple} from '../../backend/src/apple-verifier.mjs';

class FixtureError extends Error {constructor(code){super(code);this.code=code;}}
const reject=code=>{throw new FixtureError(code);};

const exact=(input,fields,code='fixtureInvalidRequest')=>{
  if(!input||Object.getPrototypeOf(input)!==Object.prototype||Object.keys(input).sort().join(',')!==[...fields].sort().join(','))reject(code);
};

export function createM4IdentityObserver({authority,appleVerifier,namespace,getGeneration}){
  const state=authorityState(authority),config=state?.config;
  if(!config||config.environment!=='development'||!isAppleVerifier(appleVerifier,'development')||typeof getGeneration!=='function'||typeof namespace!=='string'||!namespace.length)reject('fixtureUnauthorized');
  const clock=config.clock,key=config.accountHMACKey,keyDigest=sha256(key),fingerprint=config.fingerprint,generation=getGeneration();
  const observations=new Map();let invalidated=false;
  function gate(){
    const now=clock.now();
    if(invalidated||authorityState(authority)!==state||state.config!==config||config.environment!=='development'||
       config.clock!==clock||config.accountHMACKey!==key||sha256(config.accountHMACKey)!==keyDigest||
       config.fingerprint!==fingerprint||getGeneration()!==generation||!isAppleVerifier(appleVerifier,'development')||
       !Number.isSafeInteger(now)||now<0)reject('fixtureUnauthorized');
    return now;
  }
  gate();
  return {
    beginObservation(){
      const now=gate();for(const [id,pending]of observations)if(pending.expiresAt<now)observations.delete(id);
      if(observations.size>=128)reject('fixtureUnavailable');
      const observationID=randomUUID(),nonce=randomBytes(32).toString('hex'),expiresAt=now+60;
      if(!Number.isSafeInteger(expiresAt))reject('fixtureUnauthorized');
      observations.set(observationID,{nonce,issuedAt:now,expiresAt});
      return {observationID,nonce,issuedAt:now,expiresAt};
    },
    async observeIdentity(input){
      exact(input,['observationID','identityToken'],'fixtureUnauthorized');
      const {observationID,identityToken}=input;
      if(typeof observationID!=='string'||typeof identityToken!=='string')reject('fixtureUnauthorized');
      const pending=observations.get(observationID);observations.delete(observationID);
      const before=gate();if(!pending||before>pending.expiresAt)reject('fixtureUnauthorized');
      let verified;
      try{verified=await appleVerifier.verify(identityToken,pending.nonce);}
      catch(error){gate();reject(error.code==='unavailable'?'fixtureUnavailable':'fixtureUnauthorized');}
      const now=gate();
      if(!isVerifiedApple(verified,'development')||verified.environment!=='development'||verified.nonce!==pending.nonce||
         verified.issuedAt<pending.issuedAt||verified.issuedAt>now||now>pending.expiresAt)reject('fixtureUnauthorized');
      return {kind:'currentIdentity',environment:'development',namespace,observationID,
        accountID:accountIDForAppleIdentity(config.accountHMACKey,verified),observedAt:now,expiresAt:pending.expiresAt};
    },
    invalidate(){invalidated=true;observations.clear();}
  };
}

export async function openM4AuthorityFixture({databasePath,clock={now:()=>Math.floor(Date.now()/1000)},faults={},fetchJWKS}={}){
  databasePath??=join(mkdtempSync(join(tmpdir(),'m4-empty-authority-')),'authority.sqlite');
  if(!isAbsolute(databasePath)||existsSync(databasePath)||existsSync(databasePath+'-wal')||existsSync(databasePath+'-shm'))reject('fixtureInvalidRequest');
  closeSync(openSync(databasePath,'wx',0o600));
  const namespace='m4-fixture-'+randomUUID();
  const receiptPrivateKey=generateKeyPairSync('ed25519').privateKey;
  const config={databasePath,clock,faults,environment:'development',receiptKeyID:'m4-fixture-v1',
    accountHMACKey:randomBytes(32),tokenDerivationKey:randomBytes(32),receiptPrivateKey};
  const authority=createAuthority(config),setup=await authSetup({authority,clock},{fetchJWKS});
  const observer=createM4IdentityObserver({authority,appleVerifier:setup.verifier,namespace,getGeneration:()=>0});
  const server=createHTTPServer({authority,appleVerifier:setup.verifier,deviceAuth:setup.auth});
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  let closed=false,closing;
  const ensureOpen=()=>{if(closed)reject('fixtureClosed');};
  return {
    get metadata(){return {environment:'development',namespace,baseURL:'http://127.0.0.1:'+server.address().port,
      publicKey:rawPublicKey(receiptPrivateKey),keyID:config.receiptKeyID,now:clock.now()};},
    beginObservation(){ensureOpen();return observer.beginObservation();},
    observeIdentity(input){ensureOpen();return observer.observeIdentity(input);},
    issueApple({purpose,nonce,identity}){ensureOpen();if(!['observation','authentication'].includes(purpose)||!['primary','alternate'].includes(identity)||typeof nonce!=='string'||!/^[a-f0-9]{64}$/.test(nonce))reject('fixtureInvalidRequest');const now=clock.now();return {identityToken:appleJWT({iss:'https://appleid.apple.com',sub:'m4-fixture-'+identity+'-subject',aud:'test.football',nonce,iat:now,exp:now+(purpose==='observation'?60:300)}),authorizationCode:randomBytes(32).toString('base64url')};},
    close(){if(!closing){closed=true;observer.invalidate();closing=(async()=>{await new Promise((resolve,reject)=>server.close(error=>error?reject(error):resolve()));authority.close();})();}return closing;}
  };
}
