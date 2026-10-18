import {writeFileSync,chmodSync,existsSync} from 'node:fs';
import {dirname,join} from 'node:path';
import {startFixtureAuthority,openHTTPFixture} from '../support.mjs';
export async function operationalFixture({http=false}={}){
 const h=http?await openHTTPFixture():undefined,f=h?.f??await startFixtureAuthority(),directory=dirname(f.config.databasePath);
 const paths={accountHMACKeyFile:join(directory,'account.key'),tokenDerivationKeyFile:join(directory,'token.key'),receiptPrivateKeyFile:join(directory,'receipt.pem')};
 writeFileSync(paths.accountHMACKeyFile,f.config.accountHMACKey,{mode:0o600});writeFileSync(paths.tokenDerivationKeyFile,f.config.tokenDerivationKey,{mode:0o600});writeFileSync(paths.receiptPrivateKeyFile,f.config.receiptPrivateKey.export({type:'pkcs8',format:'pem'}),{mode:0o600});
 const config={databasePath:f.config.databasePath,environment:'development',...paths},configPath=join(directory,'ops.json');writeFileSync(configPath,JSON.stringify(config),{mode:0o600});
 const modes=()=>{for(const file of [f.config.databasePath,f.config.databasePath+'-wal',f.config.databasePath+'-shm'])if(existsSync(file))chmodSync(file,0o600);};modes();
 return {f,h,directory,paths,configPath,config,modes,close:()=>h?h.close():f.close()};
}
