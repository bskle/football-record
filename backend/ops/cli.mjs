import {preflight} from './config.mjs';
try {const [operation,...args]=process.argv.slice(2);let result;if(operation==='preflight'&&args.length===1)result=preflight(args[0]);else throw Error();process.stdout.write(JSON.stringify(result)+'\n');}
catch{process.stdout.write(JSON.stringify({ok:false,code:'unavailable'})+'\n');process.exitCode=1;}
