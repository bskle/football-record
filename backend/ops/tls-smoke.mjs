import {createServer,request as httpsRequest} from 'node:https';
import {request as httpRequest} from 'node:http';
import {readPrivate,unavailable} from './config.mjs';
import {parseStrictJSON} from '../src/receipt.mjs';
const version=v=>typeof v==='string'&&/^[a-f0-9]{40}$/.test(v);
const loopback=u=>['127.0.0.1','[::1]'].includes(u.hostname);
const lookup=(name,options,cb)=>options.all?cb(null,[{address:'127.0.0.1',family:4}]):cb(null,'127.0.0.1',4);
export function createLocalTLSProxy({keyFile,certFile,upstreamURL,sourceVersion}){
 try {const upstream=new URL(upstreamURL);if(upstream.protocol!=='http:'||!loopback(upstream)||upstream.pathname!=='/'||upstream.username||upstream.password||upstream.search||upstream.hash||!version(sourceVersion))unavailable();
  const server=createServer({key:readPrivate(keyFile),cert:readPrivate(certFile),minVersion:'TLSv1.2'},(req,res)=>{
   const fail=(status=503,code='unavailable')=>{if(!res.headersSent&&!res.destroyed){res.writeHead(status,{'content-type':'application/json','connection':'close'});res.end(JSON.stringify({code,requestID:'local-smoke',retryable:false}));}};
   if(req.headers.host!=='localhost:'+server.address().port){fail(421);return;}if(!req.url.startsWith('/')||Number(req.headers['content-length']??0)>16384){fail(422,'invalidPayload');return;}
   let size=0;const chunks=[];req.on('error',()=>fail());req.on('data',b=>{size+=b.length;if(size>16384){req.pause();fail(422,'invalidPayload');}else chunks.push(b);});
   req.on('end',()=>{if(size>16384||res.writableEnded)return;const headers={};for(const key of ['content-type','authorization','x-device-pop'])if(req.headers[key]!==undefined)headers[key]=req.headers[key];
    const body=Buffer.concat(chunks);headers['content-length']=body.length;
    const proxy=httpRequest({hostname:upstream.hostname.replace(/^\[|\]$/g,''),port:upstream.port,method:req.method,path:req.url,headers,timeout:1000},response=>{let total=0;const out=[];response.on('data',b=>{total+=b.length;if(total>32768){response.destroy();fail();}else out.push(b);});response.on('error',()=>fail());response.on('end',()=>{if(total>32768||res.writableEnded)return;res.writeHead(response.statusCode,{'content-type':response.headers['content-type']??'application/json','x-football-reference-version':sourceVersion});res.end(Buffer.concat(out));});});proxy.on('timeout',()=>proxy.destroy());proxy.on('error',()=>fail());proxy.end(body);
   });
  });server.on('tlsClientError',()=>{});const listen=server.listen.bind(server);server.listen=(port,host,callback)=>{if(!Number.isInteger(port)||port<0||port>65535||!['127.0.0.1','::1'].includes(host))unavailable();return listen(port,host,callback);};return server;
 }catch{unavailable();}
}
async function get(url,ca,method,path,body,timeoutMs){
 return new Promise((resolve,reject)=>{const req=httpsRequest(new URL(path,url),{method,ca,rejectUnauthorized:true,minVersion:'TLSv1.2',lookup,family:4,timeout:timeoutMs,headers:{'content-type':'application/json'}},res=>{let size=0;const chunks=[];res.on('data',b=>{size+=b.length;if(size>32768)res.destroy();else chunks.push(b);});res.on('error',reject);res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,body:Buffer.concat(chunks)}));});req.on('error',reject);req.on('timeout',()=>req.destroy());req.end(body);});
}
export async function runContractSmoke({url,caFile,expectedVersion,timeoutMs=1000}){
 try {const u=new URL(url);if(u.protocol!=='https:'||!['localhost','127.0.0.1'].includes(u.hostname)||u.pathname!=='/'||u.username||u.password||u.search||u.hash||!version(expectedVersion)||!Number.isInteger(timeoutMs)||timeoutMs<1||timeoutMs>5000)unavailable();const ca=readPrivate(caFile);
  for(const [method,path,body,status,code]of [['POST','/v1/auth/challenges','{"version":1,"version":1}',422,'invalidPayload'],['GET','/v1/requests/local-smoke',undefined,401,'unauthorized'],['GET','/v1/local-smoke-unregistered',undefined,404,'notFound']]){
   const response=await get(u,ca,method,path,body,timeoutMs);if(response.status!==status||response.headers['x-football-reference-version']!==expectedVersion)unavailable();const result=parseStrictJSON(response.body.toString('utf8'));if(!result||Object.keys(result).some(k=>!['code','requestID','retryable','retryAfterSeconds'].includes(k))||result.code!==code||typeof result.retryable!=='boolean')unavailable();
  }return {ok:true,code:'localTLSSmokeComplete',checks:3};
 }catch{unavailable();}
}
