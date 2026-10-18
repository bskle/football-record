import {constants,openSync,closeSync,fstatSync,lstatSync,readFileSync,existsSync} from 'node:fs';
import {isAbsolute,dirname} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {authorityConfig} from '../src/config.mjs';
import {parseStrictJSON} from '../src/receipt.mjs';
export function unavailable(){throw Object.assign(new Error('unavailable'),{code:'unavailable'});}
export function privateDirectory(path){const s=lstatSync(path);if(!isAbsolute(path)||!s.isDirectory()||s.isSymbolicLink()||(s.mode&0o077)!==0||s.uid!==process.getuid())unavailable();}
export function privateFile(path){if(typeof path!=='string'||!isAbsolute(path))unavailable();privateDirectory(dirname(path));const s=lstatSync(path);if(!s.isFile()||s.isSymbolicLink()||(s.mode&0o077)!==0||s.uid!==process.getuid())unavailable();return s;}
export function readPrivate(path,limit=16384){const s=privateFile(path);if(s.size>limit)unavailable();const fd=openSync(path,constants.O_RDONLY|constants.O_NOFOLLOW);try{const actual=fstatSync(fd);if(actual.ino!==s.ino||actual.dev!==s.dev)unavailable();return readFileSync(fd);}finally{closeSync(fd);}}
export function inspectDatabase(config){
 privateFile(config.databasePath);for(const suffix of ['-wal','-shm'])if(existsSync(config.databasePath+suffix))privateFile(config.databasePath+suffix);
 const db=new DatabaseSync(config.databasePath,{readOnly:true,allowExtension:false});
 try{if(db.prepare('PRAGMA user_version').get().user_version!==2||db.prepare('PRAGMA integrity_check').get().integrity_check!=='ok'||db.prepare("SELECT value FROM metadata WHERE key='configuration'").get()?.value!==config.fingerprint)unavailable();}
 finally{db.close();}
}
export function readConfiguration(path){
 try{const v=parseStrictJSON(readPrivate(path,8192).toString('utf8')),required=['databasePath','environment','accountHMACKeyFile','tokenDerivationKeyFile','receiptPrivateKeyFile'];
  if(!v||Object.getPrototypeOf(v)!==Object.prototype||Object.keys(v).some(k=>![...required,'receiptKeyID'].includes(k))||required.some(k=>!Object.hasOwn(v,k))||v.environment!=='development'||(v.receiptKeyID!==undefined&&!/^[A-Za-z0-9._:-]{1,128}$/.test(v.receiptKeyID)))unavailable();
  return authorityConfig({databasePath:v.databasePath,environment:v.environment,receiptKeyID:v.receiptKeyID,accountHMACKey:readPrivate(v.accountHMACKeyFile),tokenDerivationKey:readPrivate(v.tokenDerivationKeyFile),receiptPrivateKey:readPrivate(v.receiptPrivateKeyFile).toString('utf8')});
 }catch{unavailable();}
}
export function preflight(path){try{inspectDatabase(readConfiguration(path));return {ok:true,code:'ready',environment:'development'};}catch{unavailable();}}
