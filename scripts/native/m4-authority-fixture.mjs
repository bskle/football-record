import {mkdtempSync,existsSync,openSync,closeSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,isAbsolute,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createInterface} from 'node:readline';
import {generateKeyPairSync,randomBytes,randomUUID} from 'node:crypto';
import {createAuthority,authorityState} from '../../backend/src/authority.mjs';
import {createHTTPServer} from '../../backend/src/http.mjs';
import {authSetup,appleJWT} from '../../backend/test/support.mjs';
import {rawPublicKey,sha256,parseStrictJSON} from '../../backend/src/receipt.mjs';
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
  if(typeof databasePath!=='string'||!isAbsolute(databasePath)||existsSync(databasePath)||existsSync(databasePath+'-wal')||existsSync(databasePath+'-shm'))reject('fixtureInvalidRequest');
  closeSync(openSync(databasePath,'wx',0o600));
  const namespace='m4-fixture-'+randomUUID(),receiptPrivateKey=generateKeyPairSync('ed25519').privateKey;
  let config={databasePath,clock,faults,environment:'development',receiptKeyID:'m4-fixture-v1',
    accountHMACKey:randomBytes(32),tokenDerivationKey:randomBytes(32),receiptPrivateKey};
  let authority,server,observer,metadata,phase='opening',generation=0,accepting=false;
  let restartPromise,closePromise,revocation,revokerPromise;
  const inflightHTTP=new Set(),inflightControls=new Set();
  const ensureOpen=()=>{if(phase!=='open')reject('fixtureClosed');};
  const track=(set,promise)=>{set.add(promise);promise.then(()=>set.delete(promise),()=>set.delete(promise));return promise;};
  const joinTasks=async set=>{while(set.size)await Promise.allSettled([...set]);};
  async function start(){
    authority=createAuthority(config);config=authorityState(authority).config;
    const setup=await authSetup({authority,clock},{fetchJWKS});
    observer=createM4IdentityObserver({authority,appleVerifier:setup.verifier,namespace,getGeneration:()=>generation});
    server=createHTTPServer({authority,appleVerifier:setup.verifier,deviceAuth:setup.auth});
    const handlers=server.listeners('request');if(handlers.length!==1)reject('fixtureUnavailable');
    const handler=handlers[0];server.removeListener('request',handler);
    server.on('request',(request,response)=>{
      if(!accepting){response.writeHead(503,{'content-type':'application/json'});response.end('{"code":"unavailable","requestID":"unknown","retryable":true}');return;}
      track(inflightHTTP,Promise.resolve(handler(request,response)));
    });
    await new Promise((resolve,reject)=>{const failed=error=>reject(error);server.once('error',failed);server.listen(0,'127.0.0.1',()=>{server.removeListener('error',failed);resolve();});});
    metadata={environment:'development',namespace,baseURL:'http://127.0.0.1:'+server.address().port,
      publicKey:rawPublicKey(receiptPrivateKey),keyID:config.receiptKeyID};accepting=true;
  }
  async function drain(){
    accepting=false;
    const networkClosed=server?.listening?new Promise((resolve,reject)=>server.close(error=>error?reject(error):resolve())):Promise.resolve();
    await Promise.all([networkClosed,joinTasks(inflightHTTP),joinTasks(inflightControls)]);
  }
  try{await start();phase='open';}catch(error){accepting=false;await drain();authority?.close();throw error;}
  const fixture={
    get metadata(){return {...metadata,now:clock.now()};},
    beginObservation(){ensureOpen();return observer.beginObservation();},
    observeIdentity(input){ensureOpen();return track(inflightControls,observer.observeIdentity(input));},
    issueApple(input){
      ensureOpen();exact(input,['purpose','nonce','identity']);const {purpose,nonce,identity}=input;
      if(!['observation','authentication'].includes(purpose)||!['primary','alternate'].includes(identity)||typeof nonce!=='string'||!/^[a-f0-9]{64}$/.test(nonce))reject('fixtureInvalidRequest');
      const now=clock.now(),identityToken=appleJWT({iss:'https://appleid.apple.com',sub:'m4-fixture-'+identity+'-subject',aud:'test.football',nonce,iat:now,exp:now+(purpose==='observation'?60:300)});
      const authorizationCode=randomBytes(32).toString('base64url');revocation?.registerCode(authorizationCode,identityToken);
      return {identityToken,authorizationCode};
    },
    enableRevoker(){
      ensureOpen();if(revocation)return Promise.resolve({enabled:true});if(revokerPromise)return revokerPromise;
      revokerPromise=track(inflightControls,(async()=>{
        const {startRevocationFixture}=await import('../../backend/test/apple-revocation-support.mjs');
        revocation=await startRevocationFixture({clock});config.appleRevoker=revocation.revoker;ensureOpen();return {enabled:true};
      })());
      revokerPromise.then(()=>{revokerPromise=undefined;},()=>{revokerPromise=undefined;});return revokerPromise;
    },
    setFault(input){
      ensureOpen();exact(input,['name','value']);const {name,value}=input;
      const methods=['challenge','authenticate','recover','registerWatch','recoverWatch','acquire','terminate','liveStatus','peerGrant'];
      if(!((['beforeCommit','afterCommitResponseLost'].includes(name)&&typeof value==='boolean')||
        (name==='dropResponseAfterOperation'&&(value===null||methods.includes(value)))))reject('fixtureInvalidRequest');
      faults[name]=value===null?undefined:value;return {applied:true};
    },
    restart(){
      ensureOpen();phase='restarting';generation++;observer.invalidate();
      restartPromise=(async()=>{await drain();authority.close();await start();phase='open';return fixture.metadata;})();
      restartPromise.catch(()=>{phase='failed';});return restartPromise;
    },
    close(){
      if(closePromise)return closePromise;
      closePromise=(async()=>{
        if(phase==='restarting')await restartPromise.catch(()=>{});
        phase='closing';generation++;observer.invalidate();await drain();
        authority.close();if(revocation)await revocation.close();phase='closed';return {closed:true};
      })();return closePromise;
    }
  };
  return fixture;
}

const safeCodes=new Set(['fixtureInvalidRequest','duplicateRequest','fixtureUnauthorized','fixtureUnavailable','fixtureClosed']);
const safeOperations=new Set(['startup','identity.begin','apple','identity.observe','revoker','fault','restart','close','shutdown']);
const errorCode=error=>safeCodes.has(error?.code)?error.code:error?.code==='unauthorized'?'fixtureUnauthorized':'fixtureUnavailable';
async function runCLI(){
  const diagnostic=(code,operation)=>process.stderr.write(JSON.stringify({code,operation:safeOperations.has(operation)?operation:'unknown'})+'\n');
  process.removeAllListeners('warning');process.on('warning',()=>diagnostic('runtimeWarning','startup'));
  const emit=value=>process.stdout.write(JSON.stringify(value)+'\n');
  const f=await openM4AuthorityFixture();
  const input=createInterface({input:process.stdin});let stopping=false,stopPromise;
  const seen=new Set(),fields={'identity.begin':[],apple:['purpose','nonce','identity'],'identity.observe':['observationID','identityToken'],revoker:[],fault:['name','value'],restart:[],close:[]};
  const stop=()=>{if(!stopPromise){stopping=true;stopPromise=f.close().then(()=>{input.close();process.stdin.pause();});}return stopPromise;};
  const signal=()=>{stop().catch(()=>{diagnostic('fixtureUnavailable','shutdown');process.exitCode=1;});};process.on('SIGTERM',signal);
  emit({version:1,type:'ready',...f.metadata});
  try{
    for await(const line of input){
      if(stopping)break;let requestID='unknown',operation='unknown';
      try{
        if(Buffer.byteLength(line)>16384)reject('fixtureInvalidRequest');
        let r;try{r=parseStrictJSON(line);}catch{reject('fixtureInvalidRequest');}
        if(!r||Object.getPrototypeOf(r)!==Object.prototype||r.version!==1||typeof r.requestID!=='string'||!/^[A-Za-z0-9._:-]{1,128}$/.test(r.requestID))reject('fixtureInvalidRequest');
        requestID=r.requestID;operation=r.op;
        if(seen.has(requestID))reject('duplicateRequest');if(seen.size>=4096)reject('fixtureUnavailable');seen.add(requestID);
        if(typeof operation!=='string'||!Object.hasOwn(fields,operation))reject('fixtureInvalidRequest');
        exact(r,['version','requestID','op',...fields[operation]]);let result;
        if(operation==='identity.begin')result=f.beginObservation();
        else if(operation==='apple')result=f.issueApple({purpose:r.purpose,nonce:r.nonce,identity:r.identity});
        else if(operation==='identity.observe')result=await f.observeIdentity({observationID:r.observationID,identityToken:r.identityToken});
        else if(operation==='revoker')result=await f.enableRevoker();
        else if(operation==='fault')result=f.setFault({name:r.name,value:r.value});
        else if(operation==='restart')result=await f.restart();
        else if(operation==='close')result=await f.close();
        else reject('fixtureInvalidRequest');
        emit({version:1,requestID,ok:true,result});
        if(operation==='close'){await stop();break;}
      }catch(error){emit({version:1,requestID,ok:false,error:{code:errorCode(error)}});}
    }
  }finally{try{await stop();}finally{process.removeListener('SIGTERM',signal);}}
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  await runCLI().catch(()=>{process.stderr.write('{"code":"fixtureUnavailable","operation":"startup"}\n');process.exitCode=1;});
}
