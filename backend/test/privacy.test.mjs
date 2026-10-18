import test from 'node:test';
import assert from 'node:assert/strict';
import {startFixtureAuthority} from './support.mjs';
const base={version:1,requestID:'metric-one',metric:'activeDay',count:1,appVersion:'1.0',osFamily:'iOS',osMajor:17,qualification:'free'};

test('anonymous metric rejects business health identity nested and oversized values without persistence',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());
 for(const key of ['events','score','playerName','teamName','heartRate','gps','venue','email','appleID'])assert.throws(()=>f.authority.analytics(f.context,{...base,[key]:'FORBIDDEN-SENTINEL'}),e=>e.code==='invalidPayload');
 for(const change of [{metric:{nested:'FORBIDDEN-SENTINEL'}},{appVersion:'x'.repeat(17000)},{count:Infinity}])assert.throws(()=>f.authority.analytics(f.context,{...base,...change}),e=>e.code==='invalidPayload');
 assert.equal(JSON.stringify(f.inspect('SELECT * FROM requests')).includes('FORBIDDEN-SENTINEL'),false);
 const schema=f.inspect("SELECT sql FROM sqlite_master WHERE type='table'").map(r=>r.sql).join(' ');for(const key of ['heartRate','playerName','teamName','appleID'])assert.equal(schema.includes(key),false);
});
test('analytics defaults off, disabling drops unsent optional queue, stable request deduplicates and no heartbeat exists',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());
 const {createAnalyticsQueue}=await import('../src/analytics.mjs');let sends=0;const q=createAnalyticsQueue({send:async()=>{sends++;}});
 q.enqueue(base);await q.flush();assert.equal(sends,0);q.setEnabled(true);q.enqueue(base);assert.equal(q.pendingCount,1);q.setEnabled(false);assert.equal(q.pendingCount,0);await q.flush();assert.equal(sends,0);
 f.authority.analytics(f.context,base);assert.equal(f.inspect('SELECT count(*) AS n FROM analytics_events')[0].n,0);
 f.config.analyticsEnabled=true;f.authority.analytics(f.context,{...base,requestID:'opted-in'});f.authority.analytics(f.context,{...base,requestID:'opted-in'});
 assert.equal(f.inspect('SELECT sum(count) AS n FROM analytics_events')[0].n,1);
 const stats=f.authority.analyticsSummary();assert.equal(stats.dau,1);assert.equal(stats.wau,1);assert.equal(stats.mau,1);
});

test('anonymous summary reports match outcomes device/qualification buckets and integer success ratios',async t=>{
 const f=await startFixtureAuthority();t.after(()=>f.close());f.config.analyticsEnabled=true;
 for(const [metric,count]of [['matchCompleted',2],['matchIncomplete',1],['syncSucceeded',3],['syncFailed',1],['recoverySucceeded',1],['recoveryFailed',1]])f.authority.analytics(f.context,{...base,requestID:'summary-'+metric,metric,count});
 const s=f.authority.analyticsSummary();assert.equal(s.matchCount,3);assert.deepEqual(s.rates.sync,{succeeded:3,total:4});assert.deepEqual(s.rates.recovery,{succeeded:1,total:2});assert.ok(s.devices.some(x=>x.role==='phone'&&x.count===1));assert.ok(s.qualifications.some(x=>x.qualification==='free'));
 const {createAnalyticsQueue}=await import('../src/analytics.mjs');const queue=createAnalyticsQueue({send:async()=>{}});queue.setEnabled(true);queue.enqueue(base);assert.throws(()=>queue.enqueue({...base,count:2}),e=>e.code==='idempotencyConflict');
});
