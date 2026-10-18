import {backupAuthority} from '../../ops/backup.mjs';
await backupAuthority(process.argv[2],process.argv[3],{afterSnapshot:()=>new Promise(()=>process.send({paused:true}))});
