import test from 'node:test';
import assert from 'node:assert/strict';
import {chmodSync,readFileSync,writeFileSync,renameSync,symlinkSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import {operationalFixture} from './support/operational-fixture.mjs';

test('private explicit configuration preflight reuses authority fingerprint without mutating existing DB',async t=>{
 const {preflight}=await import('../ops/config.mjs'),f=await operationalFixture();t.after(()=>f.close());const before=f.f.inspect('SELECT * FROM metadata');assert.deepEqual(preflight(f.configPath),{ok:true,code:'ready',environment:'development'});assert.deepEqual(f.f.inspect('SELECT * FROM metadata'),before);await f.f.restart();f.modes();assert.equal(preflight(f.configPath).ok,true);
});

test('missing key weak permissions symlink wrong key or environment fail closed with finite no-secret output',async t=>{
 const {preflight}=await import('../ops/config.mjs'),f=await operationalFixture();t.after(()=>f.close());const path=f.paths.accountHMACKeyFile,original=readFileSync(path),saved=path+'.saved';
 const rejected=()=>assert.throws(()=>preflight(f.configPath),e=>e.message==='unavailable'&&e.code==='unavailable'&&!JSON.stringify(e).includes(original.toString('base64')));
 renameSync(path,saved);rejected();renameSync(saved,path);chmodSync(path,0o644);rejected();chmodSync(path,0o600);writeFileSync(path,Buffer.alloc(32,3));rejected();writeFileSync(path,original);
 chmodSync(f.configPath,0o644);rejected();chmodSync(f.configPath,0o600);chmodSync(f.config.databasePath,0o644);rejected();f.modes();
 const link=join(f.directory,'config-link');symlinkSync(f.configPath,link);assert.throws(()=>preflight(link));writeFileSync(f.configPath,JSON.stringify({...f.config,environment:'production'}));rejected();
});

test('operator CLI has finite JSON results and never prints config keys paths or errors',async t=>{
 const f=await operationalFixture();t.after(()=>f.close());const run=()=>spawnSync(process.execPath,['backend/ops/cli.mjs','preflight',f.configPath],{encoding:'utf8'});const good=run();assert.equal(good.status,0);assert.deepEqual(JSON.parse(good.stdout),{ok:true,code:'ready',environment:'development'});
 const original=readFileSync(f.paths.tokenDerivationKeyFile);writeFileSync(f.paths.tokenDerivationKeyFile,Buffer.alloc(32,5));const bad=run();assert.equal(bad.status,1);assert.deepEqual(JSON.parse(bad.stdout),{ok:false,code:'unavailable'});for(const value of [f.configPath,original.toString('base64'),original.toString('hex')])assert.equal((bad.stdout+bad.stderr).includes(value),false);
});
