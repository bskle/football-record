import {mkdirSync,openSync,closeSync,fsyncSync,writeFileSync,copyFileSync,chmodSync,constants,readFileSync} from 'node:fs';
import {isAbsolute,dirname,join} from 'node:path';
import {DatabaseSync,backup} from 'node:sqlite';
import {authorityConfig} from '../src/config.mjs';
import {parseStrictJSON,sha256} from '../src/receipt.mjs';
import {readConfiguration,readPrivate,privateFile,privateDirectory,inspectDatabase,unavailable} from './config.mjs';
const files=['authority.sqlite','account.key','token.key','receipt.pem'];
function sync(path){const fd=openSync(path,constants.O_RDONLY);try{fsyncSync(fd);}finally{closeSync(fd);}}
function write(path,bytes){writeFileSync(path,bytes,{flag:'wx',mode:0o600});sync(path);}
function freshDirectory(path){if(!isAbsolute(path))unavailable();privateDirectory(dirname(path));mkdirSync(path,{mode:0o700});}
function configuration(directory,receiptKeyID){return authorityConfig({databasePath:join(directory,'authority.sqlite'),environment:'development',receiptKeyID,accountHMACKey:readPrivate(join(directory,'account.key')),tokenDerivationKey:readPrivate(join(directory,'token.key')),receiptPrivateKey:readPrivate(join(directory,'receipt.pem')).toString('utf8')});}
function record(path){const s=privateFile(path);return {bytes:s.size,sha256:sha256(readFileSync(path))};}
function loadBundle(directory){
 privateDirectory(directory);const m=parseStrictJSON(readPrivate(join(directory,'manifest.json')).toString('utf8'));
 if(!m||Object.keys(m).sort().join(',')!=='complete,environment,files,receiptKeyID,version'||m.version!==1||m.complete!==true||m.environment!=='development'||typeof m.receiptKeyID!=='string'||!/^[A-Za-z0-9._:-]{1,128}$/.test(m.receiptKeyID)||!m.files||Object.keys(m.files).sort().join(',')!==[...files].sort().join(','))unavailable();
 for(const file of files){const r=record(join(directory,file)),expected=m.files[file];if(!expected||Object.keys(expected).sort().join(',')!=='bytes,sha256'||r.bytes!==expected.bytes||r.sha256!==expected.sha256)unavailable();}
 inspectDatabase(configuration(directory,m.receiptKeyID));return m;
}
export async function backupAuthority(configPath,destination,{afterSnapshot,signal}={}){
 let source;
 try{const config=readConfiguration(configPath);inspectDatabase(config);if(signal?.aborted)unavailable();freshDirectory(destination);
  const target=join(destination,'authority.sqlite');write(target,Buffer.alloc(0));source=new DatabaseSync(config.databasePath,{readOnly:true,allowExtension:false});await backup(source,target);source.close();source=undefined;chmodSync(target,0o600);
  const snapshot=new DatabaseSync(target);try{snapshot.exec('PRAGMA journal_mode=DELETE;');}finally{snapshot.close();}sync(target);
  write(join(destination,'account.key'),config.accountHMACKey);write(join(destination,'token.key'),config.tokenDerivationKey);write(join(destination,'receipt.pem'),config.receiptPrivateKey.export({format:'pem',type:'pkcs8'}));
  inspectDatabase(configuration(destination,config.receiptKeyID));if(afterSnapshot)await afterSnapshot();if(signal?.aborted)unavailable();
  const manifest={version:1,complete:true,environment:'development',receiptKeyID:config.receiptKeyID,files:Object.fromEntries(files.map(file=>[file,record(join(destination,file))]))};write(join(destination,'manifest.json'),JSON.stringify(manifest));sync(destination);return {ok:true,code:'backupComplete'};
 }catch{unavailable();}finally{source?.close();}
}
export async function restoreAuthority(bundle,destination){
 try{const m=loadBundle(bundle);freshDirectory(destination);
  for(const file of files){const target=join(destination,file);copyFileSync(join(bundle,file),target,constants.COPYFILE_EXCL);chmodSync(target,0o600);sync(target);const actual=record(target);if(actual.sha256!==m.files[file].sha256||actual.bytes!==m.files[file].bytes)unavailable();}
  inspectDatabase(configuration(destination,m.receiptKeyID));const config={databasePath:join(destination,'authority.sqlite'),environment:'development',receiptKeyID:m.receiptKeyID,accountHMACKeyFile:join(destination,'account.key'),tokenDerivationKeyFile:join(destination,'token.key'),receiptPrivateKeyFile:join(destination,'receipt.pem')};write(join(destination,'config.json'),JSON.stringify(config));write(join(destination,'restore-complete.json'),JSON.stringify({version:1,complete:true}));sync(destination);return {ok:true,code:'restoreComplete'};
 }catch{unavailable();}
}
