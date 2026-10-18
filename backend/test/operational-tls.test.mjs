import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer,request} from 'node:https';
import {readFileSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {operationalFixture} from './support/operational-fixture.mjs';
import {localCertificate} from './support/operational-tls.mjs';
const version='225851d9c00feda5e1d4579293c881bdf89bb090';
async function proxy(t){const m=await import('../ops/tls-smoke.mjs'),f=await operationalFixture({http:true}),cert=localCertificate(),server=m.createLocalTLSProxy({...cert,upstreamURL:f.h.baseURL,sourceVersion:version});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(async()=>{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));await f.close();});return {m,f,cert,server,url:'https://localhost:'+server.address().port};}

test('isolated TLS front forwards unchanged strict HTTP contract and verifies local configured version',async t=>{
 const p=await proxy(t);assert.deepEqual(await p.m.runContractSmoke({url:p.url,caFile:p.cert.certFile,expectedVersion:version}),{ok:true,code:'localTLSSmokeComplete',checks:3});
});

test('bad certificate wrong URL hostname disallowed host and wrong version fail closed with finite errors',async t=>{
 const p=await proxy(t),other=localCertificate();
 for(const change of [{caFile:other.certFile},{url:p.url.replace('localhost','127.0.0.1')},{url:'https://evil.invalid:443'},{expectedVersion:'f'.repeat(40)},{url:p.url+'/path'},{url:p.url.replace('https:','http:')}])await assert.rejects(p.m.runContractSmoke({url:p.url,caFile:p.cert.certFile,expectedVersion:version,...change}),e=>e.code==='unavailable'&&e.message==='unavailable');
});

test('wrong Host header is rejected at TLS front before forwarding',async t=>{
 const p=await proxy(t);const response=await new Promise((resolve,reject)=>{const r=request(p.url,{ca:readFileSync(p.cert.certFile),family:4,lookup:(name,options,cb)=>cb(null,'127.0.0.1',4),servername:'localhost',headers:{host:'wrong.invalid'}},res=>{res.resume();res.on('end',()=>resolve(res.statusCode));});r.on('error',reject);r.end();});assert.equal(response,421);
 assert.throws(()=>p.m.createLocalTLSProxy({...p.cert,upstreamURL:'http://evil.invalid',sourceVersion:version}));assert.throws(()=>p.server.listen(0,'0.0.0.0'));
});

test('TLS smoke rejects redirects without following and bounds unresponsive handlers',async t=>{
 const {runContractSmoke}=await import('../ops/tls-smoke.mjs'),cert=localCertificate();let hits=0,hang=false;const server=createServer({key:readFileSync(cert.keyFile),cert:readFileSync(cert.certFile)},(req,res)=>{hits++;if(hang)return;res.writeHead(302,{location:'https://external.invalid/private-input'});res.end();});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>{server.closeAllConnections();return new Promise(resolve=>server.close(resolve));});const url='https://localhost:'+server.address().port;
 await assert.rejects(runContractSmoke({url,caFile:cert.certFile,expectedVersion:version,timeoutMs:100}),e=>e.code==='unavailable');assert.equal(hits,1);hang=true;await assert.rejects(runContractSmoke({url,caFile:cert.certFile,expectedVersion:version,timeoutMs:100}),e=>e.code==='unavailable');assert.equal(hits,2);
});

test('operator smoke CLI emits finite result for the isolated local TLS harness',async t=>{
 const p=await proxy(t),child=spawn(process.execPath,['backend/ops/cli.mjs','smoke',p.url,p.cert.certFile,version],{stdio:['ignore','pipe','pipe']});let output='',error='';child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>error+=b);const code=await new Promise(resolve=>child.once('exit',resolve));assert.equal(code,0);assert.deepEqual(JSON.parse(output),{ok:true,code:'localTLSSmokeComplete',checks:3});for(const value of [p.url,p.cert.keyFile,p.cert.certFile,'PRIVATE KEY'])assert.equal((output+error).includes(value),false);
});

test('standalone TLS drill creates only an isolated fixture and has no import side effect',async()=>{
 const {spawnSync}=await import('node:child_process');const result=spawnSync(process.execPath,['backend/ops/tls-drill.mjs'],{encoding:'utf8',timeout:10000});assert.equal(result.status,0);assert.deepEqual(JSON.parse(result.stdout),{ok:true,code:'localTLSSmokeComplete',checks:3});const imported=spawnSync(process.execPath,['--input-type=module','-e',"await import('./backend/ops/tls-drill.mjs')"],{encoding:'utf8',timeout:10000});assert.equal(imported.status,0);assert.equal(imported.stdout,'');
});
