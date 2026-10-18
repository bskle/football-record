import {runContractSmoke} from './tls-smoke.mjs';
import {preflight} from './config.mjs';
import {backupAuthority,restoreAuthority} from './backup.mjs';
try {const [operation,...args]=process.argv.slice(2);let result;
 if(operation==='preflight'&&args.length===1)result=preflight(args[0]);
 else if(operation==='backup'&&args.length===2)result=await backupAuthority(...args);
 else if(operation==='restore'&&args.length===2)result=await restoreAuthority(...args);
 else if(operation==='smoke'&&args.length===3)result=await runContractSmoke({url:args[0],caFile:args[1],expectedVersion:args[2]});
 else throw Error();process.stdout.write(JSON.stringify(result)+'\n');
}catch{process.stdout.write(JSON.stringify({ok:false,code:'unavailable'})+'\n');process.exitCode=1;}
