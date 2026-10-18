// Explicit isolated development-only rehearsal; never loads user configuration.
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {operationalFixture,seedOperationalState,verifyOperationalRestore} from '../test/support/operational-fixture.mjs';
import {backupAuthority,restoreAuthority} from './backup.mjs';
export async function runRestoreDrill(){const f=await operationalFixture({http:true});try{const state=await seedOperationalState(f),bundle=join(f.directory,'bundle'),restored=join(f.directory,'restored');await backupAuthority(f.configPath,bundle);await restoreAuthority(bundle,restored);return await verifyOperationalRestore(join(restored,'config.json'),state,f.f.clock);}finally{await f.close();}}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){try{process.stdout.write(JSON.stringify(await runRestoreDrill())+'\n');}catch{process.stdout.write(JSON.stringify({ok:false,code:'unavailable'})+'\n');process.exitCode=1;}}
