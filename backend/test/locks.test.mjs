import test from 'node:test';
import assert from 'node:assert/strict';
import { startFixtureAuthority, tempDB } from './support.mjs';

test('two independent workers preserve one lock across reopen', async t => {
  const f = await startFixtureAuthority({databasePath: tempDB()}); t.after(()=>f.close());
  const results = await f.raceWorkers(['request-a','request-b']);
  assert.equal(results.filter(r=>r.body.result==='held').length,1);
  assert.equal(results.filter(r=>r.body.result==='originalMatch').length,1);
  assert.equal(new Set(results.map(r=>r.body.lockID)).size,1);
  await f.restart();
  assert.equal((await f.client.liveStatus(results.find(r=>r.body.result==='held').body)).status,'held');
  assert.equal(f.inspect('SELECT count(*) AS n FROM active_locks')[0].n,1);
});

test('before commit rolls back while response lost preserves first immutable bytes', async t=>{
  const f=await startFixtureAuthority({databasePath:tempDB()});t.after(()=>f.close());
  f.faults.beforeCommit=true;
  assert.throws(()=>f.authority.acquire(f.context,f.acquire('rollback')),e=>e.code==='unavailable');
  assert.equal(f.inspect('SELECT count(*) AS n FROM active_locks')[0].n,0);
  f.faults.beforeCommit=false; f.faults.afterCommitResponseLost=true;
  assert.throws(()=>f.authority.acquire(f.context,f.acquire('lost')),e=>e.code==='responseLost');
  f.faults.afterCommitResponseLost=false;
  const bytes=f.authority.requestBytes(f.context,'lost');
  await f.restart();
  assert.deepEqual(f.authority.requestBytes(f.context,'lost'),bytes);
  assert.equal(f.authority.acquire(f.context,f.acquire('lost')).body.result,'held');
  assert.throws(()=>f.authority.acquire(f.context,{...f.acquire('lost'),matchID:'changed'}),e=>e.code==='idempotencyConflict');
});

test('exact compare release cannot free a later lock and old acquire becomes terminal', async t=>{
  const f=await startFixtureAuthority({databasePath:tempDB()});t.after(()=>f.close());
  const original=f.authority.acquire(f.context,f.acquire('start-old'));
  const end={version:1,requestID:'end-old',matchID:original.body.matchID,lockID:original.body.lockID,recordingDeviceID:original.body.recordingDeviceID,activationEpoch:f.context.activationEpoch,mode:'abnormal'};
  const released=f.authority.terminate(f.context,end);
  assert.equal(released.body.result,'releasedAbnormal');
  f.clock.advance(999999);
  const newer=f.authority.acquire(f.context,f.acquire('start-new'));
  assert.equal(newer.body.result,'held');
  assert.deepEqual(f.authority.terminate(f.context,end),released);
  assert.equal((await f.client.liveStatus(original.body)).status,'terminal');
  assert.equal((await f.client.liveStatus(newer.body)).status,'held');
  assert.equal(f.authority.acquire(f.context,f.acquire('start-old')).body.lockID,original.body.lockID);
});

test('clock and grant expiry do not release locks; normal release binds opaque assertion', async t=>{
  const f=await startFixtureAuthority({databasePath:tempDB()});t.after(()=>f.close());
  const r=f.authority.acquire(f.context,f.acquire('start'));
  f.clock.advance(86400*365);
  assert.equal(f.authority.acquire(f.context,f.acquire('other')).body.result,'originalMatch');
  const end={version:1,requestID:'normal',matchID:r.body.matchID,lockID:r.body.lockID,recordingDeviceID:r.body.recordingDeviceID,activationEpoch:f.context.activationEpoch,mode:'normal',cloudConfirmationID:'opaque-confirmation',contentCommitment:'a'.repeat(64)};
  const release=f.authority.terminate(f.context,end);
  assert.equal(release.body.result,'releasedNormal');
  assert.notEqual(release.body.requestDigest,r.body.requestDigest);
  assert.throws(()=>f.authority.terminate(f.context,{...end,contentCommitment:'b'.repeat(64)}),e=>e.code==='idempotencyConflict');
});
