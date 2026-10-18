import {readFileSync,statSync} from 'node:fs';
import {createAuthority} from './authority.mjs';
import {createAppleVerifier} from './apple-verifier.mjs';
import {createDeviceAuth} from './device-auth.mjs';
import {createHTTPServer} from './http.mjs';
function secret(path){if(typeof path!=='string'||!statSync(path).isFile()||(statSync(path).mode&0o077)!==0)throw Error('private configuration file required');return readFileSync(path);}
try{
 if(process.env.FOOTBALL_AUTH_ENV!=='development')throw Error('explicit development environment required');
 const host=process.env.FOOTBALL_AUTH_HOST??'127.0.0.1',port=Number(process.env.FOOTBALL_AUTH_PORT??8787);
 const authority=createAuthority({databasePath:process.env.FOOTBALL_AUTH_DB,accountHMACKey:secret(process.env.FOOTBALL_AUTH_ACCOUNT_KEY_FILE),tokenDerivationKey:secret(process.env.FOOTBALL_AUTH_TOKEN_KEY_FILE),receiptPrivateKey:secret(process.env.FOOTBALL_AUTH_RECEIPT_KEY_FILE).toString('utf8'),environment:'development',analyticsEnabled:process.env.FOOTBALL_AUTH_ANALYTICS==='1'});
 const appleVerifier=createAppleVerifier({audiences:(process.env.FOOTBALL_AUTH_APPLE_AUDIENCES??'').split(',').filter(Boolean),environment:'development'});
 const deviceAuth=createDeviceAuth({authority,appleVerifier});
 const server=createHTTPServer({authority,appleVerifier,deviceAuth,logger:record=>process.stdout.write(JSON.stringify(record)+'\n')});
 server.listen(port,host,()=>process.stdout.write(JSON.stringify({code:'listening',environment:'development',host,port:server.address().port})+'\n'));
 const close=()=>server.close(()=>{authority.close();process.exit(0);});process.on('SIGTERM',close);process.on('SIGINT',close);
}catch{process.stderr.write(JSON.stringify({code:'unavailable',operation:'startup',requestID:'startup',retryable:false})+'\n');process.exitCode=1;}
