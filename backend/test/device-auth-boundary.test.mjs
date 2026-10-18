import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createAuthority,authorityState} from '../src/authority.mjs';
import {createDeviceAuth} from '../src/device-auth.mjs';
import {createAppleVerifier,isAppleVerifier,isVerifiedApple} from '../src/apple-verifier.mjs';
import {startFixtureAuthority,tempDB,authSetup} from './support.mjs';

async function production(t){const f=await startFixtureAuthority();t.after(()=>f.close());const authority=createAuthority({...f.config,databasePath:tempDB(),environment:'production'});t.after(()=>authority.close());return {f,authority};}

test('production DeviceAuth rejects an unbranded same-environment verifier without calling it',async t=>{
 const {authority}=await production(t);let calls=0;
 const fake={environment:'production',verify:async()=>{calls++;return {issuer:'https://appleid.apple.com',subject:'unverified',audience:'test.football',nonce:'unverified',issuedAt:1800000000,environment:'production'};}};
 assert.equal(isAppleVerifier(fake,'production'),false);assert.throws(()=>createDeviceAuth({authority,appleVerifier:fake}),/verifier/);assert.equal(calls,0);
});

test('production DeviceAuth rejects genuine development and a copied production verifier',async t=>{
 const {f,authority}=await production(t),development=await authSetup(f),productionVerifier=createAppleVerifier({audiences:['test.football'],clock:f.clock});
 assert.throws(()=>createDeviceAuth({authority,appleVerifier:development.verifier}),/verifier/);
 const copy={...productionVerifier};assert.equal(isAppleVerifier(copy,'production'),false);assert.throws(()=>createDeviceAuth({authority,appleVerifier:copy}),/verifier/);
});

test('genuine fixed production factory constructs DeviceAuth without fetch and cannot have verify replaced',async t=>{
 const {f,authority}=await production(t),verifier=createAppleVerifier({audiences:['test.football'],clock:f.clock});let calls=0;const original=globalThis.fetch;
 try {globalThis.fetch=async()=>{calls++;throw Error('unexpected outbound attempt');};
  assert.equal(isAppleVerifier(verifier,'production'),true);assert.equal(Object.isFrozen(verifier),true);assert.throws(()=>{verifier.verify=async()=>({environment:'production'});},TypeError);assert.ok(createDeviceAuth({authority,appleVerifier:verifier}));assert.equal(calls,0);
 }finally{globalThis.fetch=original;}
});

test('after await a non-genuine context cannot create a production session even when environment changed in flight',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const setup=await authSetup(f),{r}=setup.request(setup.device());let finish,entered;
 const started=new Promise(resolve=>entered=resolve),answer=new Promise(resolve=>finish=resolve),fake={environment:'development',verify:async()=>{entered();return answer;}};
 const auth=createDeviceAuth({authority:f.authority,appleVerifier:fake}),pending=auth.authenticate(r);await started;
 const state=authorityState(f.authority),before=state.db.prepare('SELECT count(*) AS n FROM sessions').get().n;
 const claims={issuer:'https://appleid.apple.com',subject:'unverified',audience:'test.football',nonce:randomUUID(),issuedAt:f.clock.now(),environment:'production'};
 assert.equal(isVerifiedApple(claims,'production'),false);state.config.environment='production';finish(claims);
 try {await assert.rejects(pending,e=>e.code==='unauthorized'&&e.message==='unauthorized');assert.equal(state.db.prepare('SELECT count(*) AS n FROM sessions').get().n,before);assert.equal(state.db.prepare('SELECT count(*) AS n FROM devices WHERE device_id=?').get(r.deviceID).n,0);assert.equal(state.db.prepare('SELECT consumed FROM challenges WHERE challenge_id=?').get(r.challengeID).consumed,0);}
 finally{state.config.environment='development';}
});

test('explicit development controlled legacy verifier remains compatible',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());const setup=await authSetup(f),{r}=setup.request(setup.device());let calls=0;
 const fake={environment:'development',verify:async()=>{calls++;return {issuer:'https://appleid.apple.com',subject:'controlled-development-fixture',audience:'test.football',nonce:'controlled',issuedAt:f.clock.now(),environment:'development'};}};
 const auth=createDeviceAuth({authority:f.authority,appleVerifier:fake}),result=await auth.authenticate(r);assert.equal(calls,1);assert.equal(result.receipt.body.environment,'development');assert.ok(result.credential.token);
});
