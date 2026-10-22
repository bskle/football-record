import {mkdtempSync,existsSync,openSync,closeSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,isAbsolute} from 'node:path';
import {generateKeyPairSync,randomBytes,randomUUID} from 'node:crypto';
import {createAuthority} from '../../backend/src/authority.mjs';
import {createHTTPServer} from '../../backend/src/http.mjs';
import {authSetup} from '../../backend/test/support.mjs';
import {rawPublicKey} from '../../backend/src/receipt.mjs';

class FixtureError extends Error {constructor(code){super(code);this.code=code;}}
const reject=code=>{throw new FixtureError(code);};

export async function openM4AuthorityFixture({databasePath,clock={now:()=>Math.floor(Date.now()/1000)},faults={}}={}){
  databasePath??=join(mkdtempSync(join(tmpdir(),'m4-empty-authority-')),'authority.sqlite');
  if(!isAbsolute(databasePath)||existsSync(databasePath)||existsSync(databasePath+'-wal')||existsSync(databasePath+'-shm'))reject('fixtureInvalidRequest');
  closeSync(openSync(databasePath,'wx',0o600));
  const namespace='m4-fixture-'+randomUUID();
  const receiptPrivateKey=generateKeyPairSync('ed25519').privateKey;
  const config={databasePath,clock,faults,environment:'development',receiptKeyID:'m4-fixture-v1',
    accountHMACKey:randomBytes(32),tokenDerivationKey:randomBytes(32),receiptPrivateKey};
  const authority=createAuthority(config),setup=await authSetup({authority,clock});
  const server=createHTTPServer({authority,appleVerifier:setup.verifier,deviceAuth:setup.auth});
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  let closed=false,closing;
  const ensureOpen=()=>{if(closed)reject('fixtureClosed');};
  return {
    get metadata(){return {environment:'development',namespace,baseURL:'http://127.0.0.1:'+server.address().port,
      publicKey:rawPublicKey(receiptPrivateKey),keyID:config.receiptKeyID,now:clock.now()};},
    beginObservation(){ensureOpen();reject('fixtureUnavailable');},
    close(){if(!closing){closed=true;closing=(async()=>{await new Promise((resolve,reject)=>server.close(error=>error?reject(error):resolve()));authority.close();})();}return closing;}
  };
}
