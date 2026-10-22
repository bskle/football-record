import {createServer} from 'node:http';
import {authorityState} from './authority.mjs';
import {canonicalJSON,parseStrictJSON,decodeBase64URL} from './receipt.mjs';
import {routes,validatePayload} from './codec.mjs';
import {fail} from './database.mjs';
const publicCodes=new Set(['unauthorized','invalidPayload','idempotencyConflict','activationMismatch','cloudIdentityMismatch','activeMatchExists','lockMismatch','migrationBlocked','waitingPeriod','reauthenticationRequired','accountDeleted','unavailable','notFound']);
const safeID=x=>typeof x==='string'&&/^[A-Za-z0-9._:-]{1,128}$/.test(x)?x:'unknown';
async function readBody(req){let total=0,parts=[];for await(const part of req){total+=part.length;if(total<=16384)parts.push(part);}if(total>16384)fail('invalidPayload',422);return Buffer.concat(parts);}
export function createHTTPServer({authority,appleVerifier,deviceAuth,logger=()=>{},rateLimit={maxRequests:240,windowSeconds:60}}){
 if(!authorityState(authority)||!deviceAuth||!appleVerifier)throw Error('explicit authority/verifier/device-auth required');
 const {config}=authorityState(authority);let windowStart=config.clock.now(),requests=0;
 const server=createServer({maxHeaderSize:8192,requestTimeout:10000,headersTimeout:10000},async(req,res)=>{
  const started=performance.now();let requestID='unknown',operation='unknown';
  const log=code=>{try{logger({code,requestID,operation,durationMs:Math.max(0,Math.floor(performance.now()-started))});}catch{}};
  const send=(status,value)=>{const bytes=Buffer.isBuffer(value)?value:Buffer.from(canonicalJSON(value));res.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store','content-length':bytes.length});res.end(bytes);};
  try{
   if(config.clock.now()<windowStart||config.clock.now()-windowStart>=rateLimit.windowSeconds){windowStart=config.clock.now();requests=0;}
   if(++requests>rateLimit.maxRequests){const e=new Error();e.code='unavailable';e.status=429;e.retryable=true;e.retryAfterSeconds=rateLimit.windowSeconds;throw e;}
   const path=req.url;
   const getMatch=req.method==='GET'&&/^\/v1\/requests\/([A-Za-z0-9._:-]{1,128})$/.exec(path);
   const route=req.method==='POST'?routes[path]:undefined;
   if(!getMatch&&!route)fail('notFound',404);
   const bodyBytes=await readBody(req);
   let body;
   if(getMatch){if(bodyBytes.length)fail('invalidPayload',422);requestID=getMatch[1];operation='requestQuery';}
   else{
    if(!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(req.headers['content-type']??''))fail('invalidPayload',422);
    try{body=parseStrictJSON(new TextDecoder('utf-8',{fatal:true}).decode(bodyBytes));}catch{fail('invalidPayload',422);}
    requestID=safeID(body?.requestID);[operation]=route;validatePayload(operation,body);
   }
   let result,method=route?.[1];
   if(['challenge','authApple','authRecover','deleteControlChallenge','deleteControlAuthentication','deleteControlRecover'].includes(operation))result=await deviceAuth[method](body);
   else if(operation==='deleteStatus')result=authority.deleteStatus(body);
   else{
    let proof;
    try{if(req.rawHeaders.filter((v,i)=>i%2===0&&['authorization','x-device-pop'].includes(v.toLowerCase())).length!==2)throw Error();proof=parseStrictJSON(decodeBase64URL(req.headers['x-device-pop']).toString('utf8'));}catch{fail('unauthorized',401);}
    const ctx=deviceAuth.authenticateRequest({authorization:req.headers.authorization,proof,method:req.method,path,requestID,bodyBytes});
    result=getMatch?authority.requestBytes(ctx,requestID):await authority[method](ctx,body);
   }
   if(typeof method==='string'&&config.faults?.dropResponseAfterOperation===method){res.destroy();log('unavailable');return;}
   send(200,result);log('ok');
  }catch(error){
   if(error.code==='responseLost'){res.destroy();log('unavailable');return;}
   const code=publicCodes.has(error.code)?error.code:'unavailable',status=publicCodes.has(error.code)?error.status??503:503;
   const payload={code,requestID,retryable:error.retryable===true};if(status===429)payload.retryAfterSeconds=error.retryAfterSeconds;
   if(!res.destroyed)send(status,payload);log(code);
  }
 });
 const listen=server.listen.bind(server);
 server.listen=function(port,host,callback){
  if(typeof port==='object'){if(!['127.0.0.1','::1',undefined].includes(port.host)||port.path)throw Error('reference authority must listen on loopback');return listen({...port,host:port.host??'127.0.0.1'},host);}
  if(typeof host==='function'){callback=host;host=undefined;}host??='127.0.0.1';if(!['127.0.0.1','::1'].includes(host)||!Number.isInteger(port)||port<0||port>65535)throw Error('reference authority must listen on loopback');return listen(port,host,callback);
 };
 return server;
}
