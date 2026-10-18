import test from 'node:test';
import assert from 'node:assert/strict';
import {join} from 'node:path';
import {sha256} from '../src/receipt.mjs';
import {readFileSync,writeFileSync,renameSync,statSync,existsSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {operationalFixture,seedOperationalState,verifyOperationalRestore} from './support/operational-fixture.mjs';

test('online SQLite WAL plus matching private keys restores actual HTTP receipts lock epoch fence and deletion capability',async t=>{
 const {backupAuthority,restoreAuthority}=await import('../ops/backup.mjs'),f=await operationalFixture({http:true});t.after(()=>f.close());const state=await seedOperationalState(f),bundle=join(f.directory,'bundle'),target=join(f.directory,'restored');assert.ok(statSync(f.config.databasePath+'-wal').size>0);
 assert.deepEqual(await backupAuthority(f.configPath,bundle),{ok:true,code:'backupComplete'});assert.equal(statSync(bundle).mode&0o777,0o700);assert.deepEqual(await restoreAuthority(bundle,target),{ok:true,code:'restoreComplete'});assert.equal(statSync(join(target,'authority.sqlite')).mode&0o777,0o600);assert.deepEqual(await verifyOperationalRestore(join(target,'config.json'),state,f.f.clock),{ok:true,code:'restoreDrillComplete',checks:6});
});

test('backup and restore never overwrite existing targets or original source and corruption/missing keys fail closed',async t=>{
 const {backupAuthority,restoreAuthority}=await import('../ops/backup.mjs'),f=await operationalFixture();t.after(()=>f.close());const bundle=join(f.directory,'bundle');await backupAuthority(f.configPath,bundle);const before=readFileSync(f.config.databasePath);await assert.rejects(backupAuthority(f.configPath,f.directory),e=>e.code==='unavailable');await assert.rejects(restoreAuthority(bundle,f.directory),e=>e.code==='unavailable');assert.deepEqual(readFileSync(f.config.databasePath),before);
 const key=join(bundle,'token.key'),saved=key+'.saved';renameSync(key,saved);await assert.rejects(restoreAuthority(bundle,join(f.directory,'missing')),e=>e.code==='unavailable');assert.equal(existsSync(join(f.directory,'missing')),false);renameSync(saved,key);const original=readFileSync(key);writeFileSync(key,Buffer.alloc(32,4));await assert.rejects(restoreAuthority(bundle,join(f.directory,'wrong-key')),e=>e.code==='unavailable');const manifestPath=join(bundle,'manifest.json'),manifestBytes=readFileSync(manifestPath),manifest=JSON.parse(manifestBytes);manifest.files['token.key']={bytes:32,sha256:sha256(readFileSync(key))};writeFileSync(manifestPath,JSON.stringify(manifest));await assert.rejects(restoreAuthority(bundle,join(f.directory,'wrong-fingerprint')),e=>e.code==='unavailable');writeFileSync(key,original);writeFileSync(manifestPath,manifestBytes);const corrupt=Buffer.from('corrupt');writeFileSync(join(bundle,'authority.sqlite'),corrupt);manifest.files['token.key']={bytes:original.length,sha256:sha256(original)};manifest.files['authority.sqlite']={bytes:corrupt.length,sha256:sha256(corrupt)};writeFileSync(manifestPath,JSON.stringify(manifest));await assert.rejects(restoreAuthority(bundle,join(f.directory,'corrupt')),e=>e.code==='unavailable');
});

test('interrupted after-snapshot backup cannot publish completion or restore as a valid bundle',async t=>{
 const {backupAuthority,restoreAuthority}=await import('../ops/backup.mjs'),f=await operationalFixture();t.after(()=>f.close());const partial=join(f.directory,'partial');await assert.rejects(backupAuthority(f.configPath,partial,{afterSnapshot(){throw Error('controlled interruption');}}),e=>e.code==='unavailable');assert.equal(existsSync(join(partial,'manifest.json')),false);await assert.rejects(restoreAuthority(partial,join(f.directory,'bad-restore')),e=>e.code==='unavailable');
});

test('runnable isolated operator drill prints finite checks without development secrets or paths',()=>{
 const r=spawnSync(process.execPath,['backend/ops/drill.mjs'],{encoding:'utf8',timeout:10000});assert.equal(r.status,0);assert.deepEqual(JSON.parse(r.stdout),{ok:true,code:'restoreDrillComplete',checks:6});for(const s of ['ops-code','ops-deleted-subject','PRIVATE KEY','/private/','/var/'])assert.equal((r.stdout+r.stderr).includes(s),false);
});

test('actual killed backup process leaves an incomplete private bundle that restore refuses',async t=>{
 const {fork}=await import('node:child_process'),{restoreAuthority}=await import('../ops/backup.mjs'),f=await operationalFixture();t.after(()=>f.close());const bundle=join(f.directory,'killed'),child=fork(new URL('./support/operational-interrupted-backup.mjs',import.meta.url),[f.configPath,bundle],{stdio:['ignore','pipe','pipe','ipc']});t.after(()=>child.kill());
 await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{child.kill();reject(Error('pause deadline'));},5000);child.once('error',reject);child.once('message',m=>{clearTimeout(timer);assert.equal(m.paused,true);resolve();});});const exited=new Promise(resolve=>child.once('exit',resolve));child.kill('SIGKILL');await exited;
 assert.equal(existsSync(join(bundle,'manifest.json')),false);assert.equal(statSync(bundle).mode&0o777,0o700);await assert.rejects(restoreAuthority(bundle,join(f.directory,'killed-restore')),e=>e.code==='unavailable');
});

test('importing the drill library does not generate fixtures or emit operator output',()=>{
 const r=spawnSync(process.execPath,['--input-type=module','-e',"await import('./backend/ops/drill.mjs')"],{encoding:'utf8',timeout:10000});assert.equal(r.status,0);assert.equal(r.stdout,'');
});
