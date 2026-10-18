import {fail} from './database.mjs';
import {canonicalJSON} from './receipt.mjs';
export const metrics=['registered','activeDay','matchCompleted','matchIncomplete','watchRecorded','syncSucceeded','syncFailed','recoverySucceeded','recoveryFailed'];
export function validateMetric(r){
 const fields=['version','requestID','metric','count','appVersion','osFamily','osMajor','qualification'];
 if(!r||Object.keys(r).sort().join(',')!==fields.sort().join(',')||r.version!==1||typeof r.requestID!=='string'||!/^[A-Za-z0-9._:-]{1,128}$/.test(r.requestID)||!metrics.includes(r.metric)||!Number.isSafeInteger(r.count)||r.count<1||r.count>100||typeof r.appVersion!=='string'||!/^[A-Za-z0-9._:-]{1,128}$/.test(r.appVersion)||!['iOS','watchOS'].includes(r.osFamily)||!Number.isSafeInteger(r.osMajor)||r.osMajor<1||r.osMajor>999||!['free','gifted','purchased'].includes(r.qualification))fail('invalidPayload',422);
}
export function createAnalyticsQueue({send}){
 let enabled=false,queue=[];
 return {get pendingCount(){return queue.length;},setEnabled(value){enabled=value===true;if(!enabled)queue=[];},enqueue(r){validateMetric(r);if(enabled){const prior=queue.find(x=>x.requestID===r.requestID);if(prior&&canonicalJSON(prior)!==canonicalJSON(r))fail('idempotencyConflict');if(!prior)queue.push(structuredClone(r));}},async flush(){while(enabled&&queue.length){const current=queue[0];await send(current);if(enabled&&queue[0]?.requestID===current.requestID)queue.shift();}},logout(){enabled=false;queue=[];}};
}
